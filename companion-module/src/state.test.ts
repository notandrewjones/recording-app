import { describe, expect, it } from 'vitest'
import type { RecorderInput, RecorderStatus } from './api.js'
import { definitionSignature, formatBytes, formatDuration, inputChoices, variableValues } from './state.js'

const wide: RecorderInput = {
	id: 'dl-1',
	index: 1,
	label: 'Wide',
	device: 'Duo 1',
	armed: true,
	recording: true,
	signal: true,
	format: '1080p59.94',
}
const close: RecorderInput = {
	id: 'dl-2',
	index: 2,
	label: 'Close',
	device: 'Duo 2',
	armed: false,
	recording: false,
	signal: false,
}
const status: RecorderStatus = {
	apiVersion: 2,
	recording: true,
	finalizing: false,
	freeBytes: 2_340_000_000_000,
	recordingSeconds: 3725,
	inputs: [wide, close],
}

describe('formatting', () => {
	it('formats recording time as HH:MM:SS', () => {
		expect(formatDuration(undefined)).toBe('00:00:00')
		expect(formatDuration(3725)).toBe('01:02:05')
		expect(formatDuration(100 * 3600 + 59.9)).toBe('100:00:59')
		expect(formatDuration(-5)).toBe('00:00:00')
	})

	it('formats free space in decimal units', () => {
		expect(formatBytes(2_340_000_000_000)).toBe('2.34 TB')
		expect(formatBytes(512_400_000_000)).toBe('512 GB')
		expect(formatBytes(0)).toBe('0 GB')
		expect(formatBytes(Number.NaN)).toBe('0 GB')
	})
})

describe('variableValues', () => {
	it('names per-input variables by position', () => {
		const values = variableValues(status, true)
		expect(values).toMatchObject({
			connected: true,
			recording: true,
			record_time: '01:02:05',
			free_space: '2.34 TB',
			input_count: 2,
			armed_count: 1,
			input_1_name: 'Wide',
			input_1_recording: true,
			input_1_format: '1080p59.94',
			input_2_name: 'Close',
			input_2_armed: false,
			input_2_signal: false,
			input_2_format: '',
		})
	})

	it('keeps the last status while reporting the connection as lost', () => {
		const values = variableValues(status, false)
		expect(values.connected).toBe(false)
		expect(values.recording).toBe(true)
	})

	it('is empty before the first reply', () => {
		expect(variableValues(undefined, false)).toMatchObject({
			connected: false,
			recording: false,
			input_count: 0,
			free_space: '',
		})
	})
})

describe('definitions', () => {
	it('changes signature only when IDs, positions or names change', () => {
		const base = definitionSignature([wide, close])
		expect(definitionSignature([{ ...wide, armed: false, recording: false }, close])).toBe(base)
		expect(definitionSignature([{ ...wide, label: 'Wide 2' }, close])).not.toBe(base)
		expect(definitionSignature([close, wide])).not.toBe(base)
	})

	it('keeps disconnected inputs selectable', () => {
		const remembered = new Map([
			['dl-1', 'Wide'],
			['dl-9', 'Jib'],
		])
		expect(inputChoices([wide], remembered)).toEqual([
			{ id: 'dl-1', label: '1: Wide' },
			{ id: 'dl-9', label: 'Jib (disconnected)' },
		])
	})
})
