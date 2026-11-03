import { InstanceBase, InstanceStatus, type SomeCompanionConfigField } from '@companion-module/base'
import { RecorderError, Paths, send, type Connection, type RecorderInput, type RecorderStatus } from './api.js'
import { UpdateActions, type ActionsSchema } from './actions.js'
import { DefaultPort, GetConfigFields, type ModuleConfig, type ModuleSecrets } from './config.js'
import { UpdateFeedbacks, type FeedbacksSchema } from './feedbacks.js'
import { UpdatePresets } from './presets.js'
import { definitionSignature, inputChoices, variableValues } from './state.js'
import { UpgradeScripts } from './upgrades.js'
import { UpdateVariableDefinitions, type VariablesSchema } from './variables.js'

export type ModuleSchema = {
	config: ModuleConfig
	secrets: ModuleSecrets
	actions: ActionsSchema
	feedbacks: FeedbacksSchema
	variables: VariablesSchema
}

export { UpgradeScripts }

/** While the recorder is unreachable, poll no faster than this, so logs and the network stay quiet. */
const RetryIntervalMs = 1000

export default class IsoRecorderInstance extends InstanceBase<ModuleSchema> {
	config!: ModuleConfig
	/** The last status received. Kept while disconnected, with `connected` false, so buttons dim rather than flip. */
	status: RecorderStatus | undefined
	connected = false

	private token = ''
	/** Names of inputs seen in this run, so buttons for unplugged cameras keep a readable name. */
	private remembered = new Map<string, string>()
	private signature: string | undefined
	private published: string | undefined
	private pollTimer: NodeJS.Timeout | undefined
	/** Bumped on every config change and on destroy, so replies to an old connection are ignored. */
	private generation = 0
	private lastProblem: string | undefined

	constructor(internal: unknown) {
		super(internal)
	}

	async init(config: ModuleConfig, _isFirstInit: boolean, secrets: ModuleSecrets): Promise<void> {
		this.connect(config, secrets)
	}

	async configUpdated(config: ModuleConfig, secrets: ModuleSecrets): Promise<void> {
		this.connect(config, secrets)
	}

	async destroy(): Promise<void> {
		this.generation++
		clearTimeout(this.pollTimer)
	}

	getConfigFields(): SomeCompanionConfigField[] {
		return GetConfigFields()
	}

	// MARK: State used by actions, feedbacks and presets

	input(id: string): RecorderInput | undefined {
		return this.status?.inputs.find((input) => input.id === id)
	}

	inputChoices(): { id: string; label: string }[] {
		return inputChoices(this.status?.inputs ?? [], this.remembered)
	}

	/** Sends a command and applies the status that comes back. Refusals, such as no armed inputs, are logged. */
	async command(method: 'GET' | 'POST', path: string, body?: unknown): Promise<void> {
		const generation = this.generation
		try {
			const status = await send(this.connection, method, path, { body })
			if (generation === this.generation) this.received(status)
		} catch (error) {
			if (generation !== this.generation) return
			if (error instanceof RecorderError && error.status !== undefined && !error.isAuthentication) {
				this.log('warn', `ISO Recorder refused: ${error.message}`)
				return
			}
			this.failed(error)
		}
	}

	// MARK: Connection

	private get connection(): Connection {
		return { host: this.config.host ?? '', port: this.config.port || DefaultPort, token: this.token }
	}

	private connect(config: ModuleConfig, secrets: ModuleSecrets | undefined): void {
		this.generation++
		clearTimeout(this.pollTimer)
		this.config = config
		this.token = secrets?.token ?? ''
		this.status = undefined
		this.connected = false
		this.lastProblem = undefined
		this.signature = undefined
		this.published = undefined
		this.updateDefinitions()
		this.publish()

		if (!config.host?.trim()) {
			this.updateStatus(InstanceStatus.BadConfig, 'Enter the address of the Mac running ISO Recorder.')
			return
		}
		this.updateStatus(InstanceStatus.Connecting)
		void this.poll(this.generation)
	}

	private async poll(generation: number): Promise<void> {
		try {
			const status = await send(this.connection, 'GET', Paths.status)
			if (generation !== this.generation) return
			this.received(status)
		} catch (error) {
			if (generation !== this.generation) return
			this.failed(error)
		}
		const interval = Math.min(Math.max(this.config.pollInterval || 250, 100), 5000)
		this.pollTimer = setTimeout(
			() => void this.poll(generation),
			this.connected ? interval : Math.max(interval, RetryIntervalMs),
		)
	}

	private received(status: RecorderStatus): void {
		if (!this.connected) {
			this.connected = true
			this.lastProblem = undefined
			this.updateStatus(InstanceStatus.Ok)
			this.log('info', `Connected to ISO Recorder with ${status.inputs.length} inputs.`)
		}
		this.status = status
		for (const input of status.inputs) this.remembered.set(input.id, input.label)
		if (definitionSignature(status.inputs) !== this.signature) this.updateDefinitions()
		this.publish()
	}

	private failed(error: unknown): void {
		const recorderError = error instanceof RecorderError ? error : new RecorderError(String(error))
		const problem = recorderError.isAuthentication
			? 'ISO Recorder refused the access token. Copy it again from ISO Recorder Settings > General.'
			: recorderError.message
		this.connected = false
		if (problem !== this.lastProblem) {
			this.lastProblem = problem
			this.updateStatus(
				recorderError.isAuthentication ? InstanceStatus.AuthenticationFailure : InstanceStatus.ConnectionFailure,
				problem,
			)
			this.log('warn', problem)
		}
		this.publish()
	}

	/** Resent only when the set of inputs or their names change, not on every poll. */
	private updateDefinitions(): void {
		this.signature = definitionSignature(this.status?.inputs ?? [])
		UpdateActions(this)
		UpdateFeedbacks(this)
		UpdateVariableDefinitions(this)
		UpdatePresets(this)
	}

	/** Pushes variables and re-checks feedbacks, skipping polls where nothing changed. */
	private publish(): void {
		const key = JSON.stringify([this.connected, this.status])
		if (key === this.published) return
		this.published = key
		this.setVariableValues(variableValues(this.status, this.connected))
		this.checkAllFeedbacks()
	}
}
