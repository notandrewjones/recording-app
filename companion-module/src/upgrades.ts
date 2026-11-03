import type { CompanionStaticUpgradeScript } from '@companion-module/base'
import type { ModuleConfig } from './config.js'

/**
 * Upgrade scripts for saved configs, actions and feedbacks. Once one is added it can never be removed.
 */
export const UpgradeScripts: CompanionStaticUpgradeScript<ModuleConfig>[] = []
