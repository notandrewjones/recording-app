/** One capture input, as `GET /api/v1/status` reports it. */
export interface RecorderInput {
	/** Stable hardware ID. Actions and feedbacks store this, so they survive renames and reordering. */
	id: string
	/** 1-based position in the app's multiview. */
	index: number
	/** The operator's name for the input, or the device name. */
	label: string
	device: string
	armed: boolean
	recording: boolean
	signal: boolean
	format?: string
}

export interface RecorderStatus {
	apiVersion: number
	recording: boolean
	finalizing: boolean
	freeBytes: number
	/** Present while recording. */
	recordingSeconds?: number
	inputs: RecorderInput[]
}

export interface Connection {
	host: string
	port: number
	/** Needed when Companion runs on another computer. Ignored by the app for requests from its own Mac. */
	token: string
}

export type ArmMode = 'arm' | 'disarm' | 'toggle'

export const Paths = {
	status: '/api/v1/status',
	recordStart: '/api/v1/record/start',
	recordStop: '/api/v1/record/stop',
	recordToggle: '/api/v1/record/toggle',
	marker: '/api/v1/marker',
	input: (id: string, mode: ArmMode): string => `/api/v1/inputs/${encodeURIComponent(id)}/${mode}`,
} as const

/** An error reply from the app, such as 401 for a wrong token, or a failure to reach it at all. */
export class RecorderError extends Error {
	constructor(
		message: string,
		/** The HTTP status, or undefined when the app could not be reached. */
		readonly status?: number,
	) {
		super(message)
		this.name = 'RecorderError'
	}

	get isAuthentication(): boolean {
		return this.status === 401
	}
}

export function baseUrl(connection: Pick<Connection, 'host' | 'port'>): string {
	const host = connection.host.trim()
	const bracketed = host.includes(':') && !host.startsWith('[') ? `[${host}]` : host
	return `http://${bracketed}:${connection.port}`
}

/**
 * Sends one request. Every reply that succeeds carries the full status, so callers can update buttons
 * straight away instead of waiting for the next poll.
 */
export async function send(
	connection: Connection,
	method: 'GET' | 'POST',
	path: string,
	options: { body?: unknown; timeoutMs?: number; fetch?: typeof fetch } = {},
): Promise<RecorderStatus> {
	const headers: Record<string, string> = {}
	const token = connection.token.trim()
	if (token) headers['Authorization'] = `Bearer ${token}`
	let body: string | undefined
	if (options.body !== undefined) {
		headers['Content-Type'] = 'application/json'
		body = JSON.stringify(options.body)
	}

	let response: Response
	try {
		response = await (options.fetch ?? fetch)(baseUrl(connection) + path, {
			method,
			headers,
			body,
			signal: AbortSignal.timeout(options.timeoutMs ?? 2000),
		})
	} catch (error) {
		throw new RecorderError(describeNetworkError(error))
	}

	const text = await response.text()
	let json: unknown
	try {
		json = text ? JSON.parse(text) : undefined
	} catch {
		json = undefined
	}
	if (!response.ok) {
		const message = isRecord(json) && typeof json['error'] === 'string' ? json['error'] : `HTTP ${response.status}`
		throw new RecorderError(message, response.status)
	}
	return parseStatus(json)
}

/** Reads a status reply defensively, so an older or newer app degrades instead of breaking every button. */
export function parseStatus(json: unknown): RecorderStatus {
	if (!isRecord(json) || !Array.isArray(json['inputs'])) {
		throw new RecorderError('The reply was not an ISO Recorder status. Check the host and port.')
	}
	const inputs = json['inputs'].filter(isRecord).map((input, position): RecorderInput => {
		const rawID = input['id']
		const id = typeof rawID === 'string' || typeof rawID === 'number' ? String(rawID) : ''
		const label = typeof input['label'] === 'string' && input['label'] ? input['label'] : id
		return {
			id,
			index: typeof input['index'] === 'number' ? input['index'] : position + 1,
			label,
			device: typeof input['device'] === 'string' ? input['device'] : label,
			armed: input['armed'] === true,
			recording: input['recording'] === true,
			signal: input['signal'] === true,
			format: typeof input['format'] === 'string' ? input['format'] : undefined,
		}
	})
	return {
		apiVersion: typeof json['apiVersion'] === 'number' ? json['apiVersion'] : 1,
		recording: json['recording'] === true,
		finalizing: json['finalizing'] === true,
		freeBytes: typeof json['freeBytes'] === 'number' ? json['freeBytes'] : 0,
		recordingSeconds: typeof json['recordingSeconds'] === 'number' ? json['recordingSeconds'] : undefined,
		inputs: inputs.filter((input) => input.id !== ''),
	}
}

function describeNetworkError(error: unknown): string {
	if (error instanceof Error) {
		if (error.name === 'TimeoutError' || error.name === 'AbortError') return 'No reply from ISO Recorder.'
		const cause = (error as { cause?: { code?: string } }).cause?.code
		if (cause === 'ECONNREFUSED') {
			return 'Connection refused. Is ISO Recorder running, and is "Allow control from other computers" on?'
		}
		if (cause === 'EHOSTUNREACH' || cause === 'ENETUNREACH') return 'The host is unreachable.'
		if (cause === 'ENOTFOUND') return 'The host name was not found.'
		return cause ? `${error.message} (${cause})` : error.message
	}
	return String(error)
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value)
}
