import type { CompanionPresetDefinitions, CompanionPresetSection } from '@companion-module/base'
import { Colors } from './feedbacks.js'
import type IsoRecorderInstance from './main.js'
import type { ModuleSchema } from './main.js'

export function UpdatePresets(self: IsoRecorderInstance): void {
	const variable = (name: string) => `$(${self.label}:${name})`
	const presets: CompanionPresetDefinitions<ModuleSchema> = {}

	presets['record_toggle'] = {
		type: 'simple',
		name: 'Record / Stop',
		keywords: ['record', 'stop', 'toggle'],
		style: {
			text: `REC\\n${variable('record_time')}`,
			size: '18',
			color: Colors.white,
			bgcolor: Colors.idle,
		},
		steps: [{ down: [{ actionId: 'record_toggle', options: {} }], up: [] }],
		feedbacks: [
			{ feedbackId: 'recording', options: {}, style: { bgcolor: Colors.tally, color: Colors.white } },
			{ feedbackId: 'finalizing', options: {}, style: { bgcolor: Colors.saving, color: Colors.white, text: 'SAVING' } },
			{ feedbackId: 'disconnected', options: {}, style: { bgcolor: Colors.black, color: Colors.offline } },
		],
	}
	presets['add_marker'] = {
		type: 'simple',
		name: 'Add marker',
		keywords: ['marker'],
		style: { text: 'MARK', size: '18', color: Colors.white, bgcolor: Colors.idle },
		steps: [{ down: [{ actionId: 'add_marker', options: { label: 'Marker' } }], up: [] }],
		feedbacks: [{ feedbackId: 'disconnected', options: {}, style: { bgcolor: Colors.black, color: Colors.offline } }],
	}

	const inputPresetIds: string[] = []
	for (const input of self.status?.inputs ?? []) {
		const id = `arm_${input.index}`
		inputPresetIds.push(id)
		const options = { input: input.id }
		presets[id] = {
			type: 'simple',
			name: `Arm ${input.label}`,
			keywords: ['arm', 'disarm', 'input', 'tally', input.label],
			style: { text: input.label, size: 'auto', color: Colors.white, bgcolor: Colors.idle },
			steps: [{ down: [{ actionId: 'input_arm', options: { ...options, mode: 'toggle' } }], up: [] }],
			feedbacks: [
				{ feedbackId: 'input_armed', options, style: { bgcolor: Colors.armed, color: Colors.white } },
				{ feedbackId: 'input_recording', options, style: { bgcolor: Colors.tally, color: Colors.white } },
				{ feedbackId: 'input_signal', options, isInverted: true, style: { color: Colors.warning } },
				{ feedbackId: 'disconnected', options: {}, style: { bgcolor: Colors.black, color: Colors.offline } },
			],
		}
	}

	const structure: CompanionPresetSection<ModuleSchema>[] = [
		{
			id: 'recording',
			name: 'Recording',
			definitions: ['record_toggle', 'add_marker'],
		},
		{
			id: 'inputs',
			name: 'Inputs',
			description: inputPresetIds.length
				? 'Arm or disarm an input. During a recording this punches it in or out. Dim red is armed, bright red is recording, and amber text means no signal.'
				: 'Connect to ISO Recorder to get a button for each input.',
			definitions: inputPresetIds,
		},
	]

	self.setPresetDefinitions(structure, presets)
}
