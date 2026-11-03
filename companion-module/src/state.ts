import type { RecorderInput, RecorderStatus } from './api.js'

/** Per-input variables, named by position so a button can say "Input 2" without knowing the hardware ID. */
export const InputVariableFields = ['name', 'armed', 'recording', 'signal', 'format'] as const
export type InputVariableField = (typeof InputVariableFields)[number]
export type InputVariableId = `input_${number}_${InputVariableField}`

export type VariableValues = {
	connected: boolean
	recording: boolean
	finalizing: boolean
	record_time: string
	free_space: string
	input_count: number
	armed_count: number
} & { [K in InputVariableId]?: string | boolean }

export function formatDuration(totalSeconds: number | undefined): string {
	const seconds = Math.max(0, Math.floor(totalSeconds ?? 0))
	const h = Math.floor(seconds / 3600)
	const m = Math.floor((seconds % 3600) / 60)
	const s = seconds % 60
	return [h, m, s].map((part) => String(part).padStart(2, '0')).join(':')
}

/** Decimal units, as Finder shows them. */
export function formatBytes(bytes: number): string {
	if (!Number.isFinite(bytes) || bytes <= 0) return '0 GB'
	if (bytes >= 1e12) return `${(bytes / 1e12).toFixed(2)} TB`
	return `${Math.round(bytes / 1e9)} GB`
}

export function variableValues(status: RecorderStatus | undefined, connected: boolean): VariableValues {
	const values: VariableValues = {
		connected,
		recording: status?.recording ?? false,
		finalizing: status?.finalizing ?? false,
		record_time: formatDuration(status?.recordingSeconds),
		free_space: status ? formatBytes(status.freeBytes) : '',
		input_count: status?.inputs.length ?? 0,
		armed_count: status?.inputs.filter((input) => input.armed).length ?? 0,
	}
	for (const input of status?.inputs ?? []) {
		values[`input_${input.index}_name`] = input.label
		values[`input_${input.index}_armed`] = input.armed
		values[`input_${input.index}_recording`] = input.recording
		values[`input_${input.index}_signal`] = input.signal
		values[`input_${input.index}_format`] = input.format ?? ''
	}
	return values
}

/**
 * What the action, feedback, preset and variable definitions depend on. Definitions are only resent
 * when this changes, not on every poll.
 */
export function definitionSignature(inputs: readonly RecorderInput[]): string {
	return JSON.stringify(inputs.map((input) => [input.id, input.index, input.label]))
}

/**
 * Inputs to offer in dropdowns: the connected ones, plus any seen earlier in this run, so a button for an
 * unplugged camera keeps showing its name rather than a bare ID.
 */
export function inputChoices(
	current: readonly RecorderInput[],
	remembered: ReadonlyMap<string, string>,
): { id: string; label: string }[] {
	const choices = current.map((input) => ({ id: input.id, label: `${input.index}: ${input.label}` }))
	for (const [id, label] of remembered) {
		if (!current.some((input) => input.id === id)) choices.push({ id, label: `${label} (disconnected)` })
	}
	return choices
}
