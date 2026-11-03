import type { CompanionVariableDefinitions } from '@companion-module/base'
import type IsoRecorderInstance from './main.js'
import { InputVariableFields, type InputVariableField, type VariableValues } from './state.js'

export type VariablesSchema = VariableValues

const InputFieldNames: Record<InputVariableField, string> = {
	name: 'name',
	armed: 'armed',
	recording: 'recording',
	signal: 'has signal',
	format: 'video format',
}

export function UpdateVariableDefinitions(self: IsoRecorderInstance): void {
	const definitions: CompanionVariableDefinitions<VariablesSchema> = {
		connected: { name: 'Connected to ISO Recorder' },
		recording: { name: 'Recording' },
		finalizing: { name: 'Saving files after a stop' },
		record_time: { name: 'Recording time (HH:MM:SS)' },
		free_space: { name: 'Free space on the recording drive' },
		input_count: { name: 'Number of inputs' },
		armed_count: { name: 'Number of armed inputs' },
	}
	for (const input of self.status?.inputs ?? []) {
		for (const field of InputVariableFields) {
			definitions[`input_${input.index}_${field}`] = {
				name: `Input ${input.index} ${InputFieldNames[field]} (now ${input.label})`,
			}
		}
	}
	self.setVariableDefinitions(definitions)
}
