import { Logger } from "./logging/BaseLogger";

export const getInjectedLogger = (ctx: any) => Reflect.get(ctx, Logger.symbol);
