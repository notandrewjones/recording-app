import type { ArmMode } from './api.js'
import { Paths } from './api.js'
import type IsoRecorderInstance from './main.js'

type NoOptions = Record<never, never>

export type ActionsSchema = {
	record_toggle: { options: NoOptions }
	record_start: { options: NoOptions }
	record_stop: { options: NoOptions }
	input_arm: { options: { input: string; mode: ArmMode } }
	add_marker: { options: { label: string } }
}

export function UpdateActions(self: IsoRecorderInstance): void {
	const choices = self.inputChoices()
	self.setActionDefinitions({
		record_toggle: {
			name: 'Record: toggle',
			description: 'Starts recording every armed input, or stops the session.',
			options: [],
			callback: async () => self.command('POST', Paths.recordToggle),
		},
		record_start: {
			name: 'Record: start',
			options: [],
			callback: async () => self.command('POST', Paths.recordStart),
		},
		record_stop: {
			name: 'Record: stop',
			options: [],
			callback: async () => self.command('POST', Paths.recordStop),
		},
		input_arm: {
			name: 'Input: arm / disarm',
			description: 'While recording, arming punches the input into the session and disarming stops just that input.',
			options: [
				{
					type: 'dropdown',
					id: 'input',
					label: 'Input',
					choices,
					default: choices[0]?.id ?? '',
					allowCustom: true,
					tooltip: 'Stored by hardware ID, so the button follows the camera when inputs are renamed or reordered.',
				},
				{
					type: 'dropdown',
					id: 'mode',
					label: 'Mode',
					choices: [
						{ id: 'toggle', label: 'Toggle' },
						{ id: 'arm', label: 'Arm' },
						{ id: 'disarm', label: 'Disarm' },
					],
					default: 'toggle',
				},
			],
			callback: async (action) => {
				const input = String(action.options.input ?? '').trim()
				if (!input) {
					self.log('warn', 'Input: arm / disarm has no input selected.')
					return
				}
				const mode = (['arm', 'disarm', 'toggle'] as const).find((m) => m === action.options.mode) ?? 'toggle'
				await self.command('POST', Paths.input(input, mode))
			},
		},
		add_marker: {
			name: 'Add marker',
			description: 'Marks the current moment in the recording, for the NLE exports.',
			options: [
				{
					type: 'textinput',
					id: 'label',
					label: 'Label',
					default: 'Marker',
					useVariables: true,
				},
			],
			callback: async (action) => {
				const label = String(action.options.label ?? '').trim()
				await self.command('POST', Paths.marker, label ? { label } : undefined)
			},
		},
	})
}
