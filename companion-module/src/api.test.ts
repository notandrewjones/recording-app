import { createServer, type IncomingMessage, type Server } from 'node:http'
import type { AddressInfo } from 'node:net'
import { afterEach, describe, expect, it } from 'vitest'
import { Paths, RecorderError, baseUrl, parseStatus, send } from './api.js'

const status = {
	apiVersion: 2,
	recording: true,
	finalizing: false,
	freeBytes: 1_500_000_000_000,
	recordingSeconds: 3725,
	inputs: [
		{
			id: 'dl-1',
			index: 1,
			label: 'Wide',
			device: 'DeckLink Duo (1)',
			armed: true,
			recording: true,
			signal: true,
			format: '1080p59.94',
		},
		{ id: 'dl-2', index: 2, label: 'Close', device: 'DeckLink Duo (2)', armed: false, recording: false, signal: false },
	],
}

type Seen = { method?: string; url?: string; authorization?: string; contentType?: string; body: string }
let server: Server | undefined

async function serve(
	reply: (request: IncomingMessage) => { status: number; body: unknown },
): Promise<{ port: number; seen: Seen[] }> {
	const seen: Seen[] = []
	server = createServer((request, response) => {
		let body = ''
		request.on('data', (chunk: Buffer) => (body += chunk.toString()))
		request.on('end', () => {
			seen.push({
				method: request.method,
				url: request.url,
				authorization: request.headers.authorization,
				contentType: request.headers['content-type'],
				body,
			})
			const { status: code, body: payload } = reply(request)
			response.writeHead(code, { 'Content-Type': 'application/json' })
			response.end(JSON.stringify(payload))
		})
	})
	await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve))
	return { port: (server.address() as AddressInfo).port, seen }
}

afterEach(async () => {
	await new Promise<void>((resolve) => (server ? server.close(() => resolve()) : resolve()))
	server = undefined
})

describe('send', () => {
	it('sends the token as a bearer header and returns the parsed status', async () => {
		const { port, seen } = await serve(() => ({ status: 200, body: status }))
		const result = await send({ host: '127.0.0.1', port, token: ' s3cret ' }, 'POST', Paths.recordToggle)
		expect(seen[0]).toMatchObject({ method: 'POST', url: '/api/v1/record/toggle', authorization: 'Bearer s3cret' })
		expect(result.recording).toBe(true)
		expect(result.inputs.map((input) => input.label)).toEqual(['Wide', 'Close'])
	})

	it('leaves out the authorization header when there is no token', async () => {
		const { port, seen } = await serve(() => ({ status: 200, body: status }))
		await send({ host: '127.0.0.1', port, token: '' }, 'GET', Paths.status)
		expect(seen[0]?.authorization).toBeUndefined()
	})

	it('sends a JSON body for markers', async () => {
		const { port, seen } = await serve(() => ({ status: 200, body: status }))
		await send({ host: '127.0.0.1', port, token: '' }, 'POST', Paths.marker, { body: { label: 'Goal' } })
		expect(seen[0]).toMatchObject({ contentType: 'application/json', body: '{"label":"Goal"}' })
	})

	it('reports a wrong token as an authentication error', async () => {
		const { port } = await serve(() => ({ status: 401, body: { error: 'Missing or wrong access token.' } }))
		const error = await send({ host: '127.0.0.1', port, token: 'nope' }, 'GET', Paths.status).catch((e: unknown) => e)
		expect(error).toBeInstanceOf(RecorderError)
		expect((error as RecorderError).isAuthentication).toBe(true)
		expect((error as RecorderError).message).toBe('Missing or wrong access token.')
	})

	it('passes on the app’s reason for refusing a command', async () => {
		const { port } = await serve(() => ({ status: 409, body: { error: 'No armed inputs.' } }))
		const error = (await send({ host: '127.0.0.1', port, token: '' }, 'POST', Paths.recordStart).catch(
			(e: unknown) => e,
		)) as RecorderError
		expect(error.status).toBe(409)
		expect(error.message).toBe('No armed inputs.')
	})

	it('explains a refused connection without an HTTP status', async () => {
		const { port } = await serve(() => ({ status: 200, body: status }))
		await new Promise<void>((resolve) => server!.close(() => resolve()))
		server = undefined
		const error = (await send({ host: '127.0.0.1', port, token: '' }, 'GET', Paths.status).catch(
			(e: unknown) => e,
		)) as RecorderError
		expect(error.status).toBeUndefined()
		expect(error.message).toMatch(/refused/i)
	})

	it('times out when the app does not answer', async () => {
		server = createServer(() => {})
		await new Promise<void>((resolve) => server!.listen(0, '127.0.0.1', resolve))
		const port = (server.address() as AddressInfo).port
		const error = (await send({ host: '127.0.0.1', port, token: '' }, 'GET', Paths.status, { timeoutMs: 100 }).catch(
			(e: unknown) => e,
		)) as RecorderError
		expect(error.message).toBe('No reply from ISO Recorder.')
		server.closeAllConnections()
	})

	it('rejects a reply that is not a recorder status', async () => {
		const { port } = await serve(() => ({ status: 200, body: { hello: 'world' } }))
		await expect(send({ host: '127.0.0.1', port, token: '' }, 'GET', Paths.status)).rejects.toThrow(
			/not an ISO Recorder status/,
		)
	})
})

describe('paths and addresses', () => {
	it('encodes input IDs', () => {
		expect(Paths.input('cam 1/a', 'toggle')).toBe('/api/v1/inputs/cam%201%2Fa/toggle')
		expect(Paths.input('dl-2', 'disarm')).toBe('/api/v1/inputs/dl-2/disarm')
	})

	it('brackets IPv6 hosts', () => {
		expect(baseUrl({ host: '192.168.1.20', port: 9455 })).toBe('http://192.168.1.20:9455')
		expect(baseUrl({ host: 'fe80::1', port: 9455 })).toBe('http://[fe80::1]:9455')
		expect(baseUrl({ host: ' studio-mac.local ', port: 9000 })).toBe('http://studio-mac.local:9000')
	})
})

describe('parseStatus', () => {
	it('fills in what an older app leaves out', () => {
		const parsed = parseStatus({
			recording: false,
			finalizing: false,
			freeBytes: 10,
			inputs: [{ id: 'a', label: 'A', armed: true, recording: false, signal: true }, { id: 'b' }],
		})
		expect(parsed.apiVersion).toBe(1)
		expect(parsed.recordingSeconds).toBeUndefined()
		expect(parsed.inputs.map((input) => [input.index, input.label])).toEqual([
			[1, 'A'],
			[2, 'b'],
		])
	})

	it('drops inputs without an ID and ignores wrongly typed fields', () => {
		const parsed = parseStatus({ recording: 'yes', inputs: [{ label: 'no id' }, { id: 'x', armed: 'true' }] })
		expect(parsed.recording).toBe(false)
		expect(parsed.inputs).toHaveLength(1)
		expect(parsed.inputs[0]?.armed).toBe(false)
	})
})
