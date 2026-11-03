import type { SomeCompanionConfigField } from '@companion-module/base'

export type ModuleConfig = {
	host: string
	port: number
	pollInterval: number
}

export type ModuleSecrets = {
	token: string
}

export const DefaultPort = 9455

export function GetConfigFields(): SomeCompanionConfigField[] {
	return [
		{
			type: 'static-text',
			id: 'info',
			width: 12,
			label: 'Setup',
			value:
				'In ISO Recorder, open Settings > General > Remote control. If Companion runs on another computer, turn on "Allow control from other computers" and copy the address and access token from there. On the same Mac, use 127.0.0.1 and leave the token empty.',
		},
		{
			type: 'textinput',
			id: 'host',
			label: 'ISO Recorder address',
			width: 8,
			default: '127.0.0.1',
		},
		{
			type: 'number',
			id: 'port',
			label: 'Port',
			width: 4,
			min: 1,
			max: 65535,
			default: DefaultPort,
		},
		{
			type: 'secret-text',
			id: 'token',
			label: 'Access token',
			description: 'Required when Companion runs on another computer.',
			width: 8,
		},
		{
			type: 'number',
			id: 'pollInterval',
			label: 'Status refresh (ms)',
			description: 'How often buttons check the recorder. Commands update buttons immediately.',
			width: 4,
			min: 100,
			max: 5000,
			default: 250,
		},
	]
}
