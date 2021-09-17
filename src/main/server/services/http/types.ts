import { ParameterizedContext } from "koa";
import * as KoaRouter from "koa-router";

export type KoaNext = () => Promise<any>;
export type ImageQuality = "good" | "better" | "best";
export type UpdateResult = {
    available: boolean;
    metadata: {
        version: string;
        release_date: string;
        release_name: string;
        release_notes: any;
    };
};
