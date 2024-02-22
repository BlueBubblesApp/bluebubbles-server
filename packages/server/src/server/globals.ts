import { PluginRegistry as PR } from "./lib/plugins/PluginRegistry";
import { LoggerRegistry as LR } from "./lib/logging/LoggerRegistry";

export const PluginRegistry = PR.instance;
export const LoggerRegistry = LR.instance;
