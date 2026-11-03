import type { CompanionInputFieldDropdown } from '@companion-module/base'
import type IsoRecorderInstance from './main.js'

type NoOptions = Record<never, never>
type InputOptions = { input: string }

export type FeedbacksSchema = {
	recording: { type: 'boolean'; options: NoOptions }
	finalizing: { type: 'boolean'; options: NoOptions }
	disconnected: { type: 'boolean'; options: NoOptions }
	input_armed: { type: 'boolean'; options: InputOptions }
	input_recording: { type: 'boolean'; options: InputOptions }
	input_signal: { type: 'boolean'; options: InputOptions }
}

export const Colors = {
	white: 0xffffff,
	black: 0x000000,
	idle: 0x262626,
	tally: 0xcc0000,
	armed: 0x5a1010,
	saving: 0xb36200,
	offline: 0x6b6b6b,
	warning: 0xffa500,
} as const

export function UpdateFeedbacks(self: IsoRecorderInstance): void {
	const choices = self.inputChoices()
	const inputOption: CompanionInputFieldDropdown<'input'> = {
		type: 'dropdown',
		id: 'input',
		label: 'Input',
		choices,
		default: choices[0]?.id ?? '',
		allowCustom: true,
	}
	const input = (options: InputOptions) => self.input(String(options.input ?? ''))

	self.setFeedbackDefinitions({
		recording: {
			type: 'boolean',
			name: 'Recording',
			description: 'A session is recording.',
			defaultStyle: { bgcolor: Colors.tally, color: Colors.white },
			options: [],
			callback: () => self.status?.recording === true,
		},
		finalizing: {
			type: 'boolean',
			name: 'Saving',
			description: 'Recording has stopped and files are still being finished.',
			defaultStyle: { bgcolor: Colors.saving, color: Colors.white },
			options: [],
			callback: () => self.status?.finalizing === true,
		},
		disconnected: {
			type: 'boolean',
			name: 'Connection lost',
			description: 'ISO Recorder is not answering, so other feedback on this button may be out of date.',
			defaultStyle: { bgcolor: Colors.black, color: Colors.offline },
			options: [],
			callback: () => !self.connected,
		},
		input_armed: {
			type: 'boolean',
			name: 'Input: armed',
			defaultStyle: { bgcolor: Colors.armed, color: Colors.white },
			options: [inputOption],
			callback: (feedback) => input(feedback.options)?.armed === true,
		},
		input_recording: {
			type: 'boolean',
			name: 'Input: recording',
			description: 'Tally: this input is recording now.',
			defaultStyle: { bgcolor: Colors.tally, color: Colors.white },
			options: [inputOption],
			callback: (feedback) => input(feedback.options)?.recording === true,
		},
		input_signal: {
			type: 'boolean',
			name: 'Input: has signal',
			description: 'Invert this to flag a camera that has lost its signal.',
			defaultStyle: { color: Colors.warning },
			showInvert: true,
			options: [inputOption],
			callback: (feedback) => input(feedback.options)?.signal === true,
		},
	})
}
