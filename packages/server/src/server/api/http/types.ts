import type { Next } from "koa";
import type { RouterContext } from "koa-router";

export type KoaMiddleware = (ctx: RouterContext<any, any>, _: Next) => Promise<any>;

export enum HttpMethod {
    GET = "GET",
    POST = "POST",
    PUT = "PUT",
    PATCH = "PATCH",
    DELETE = "DELETE"
}

export type HttpDefinition = {
    root: string;
    routeGroups: HttpRouteGroup[];
};

export type HttpRoute = {
    method: HttpMethod;
    path: string;
    middleware?: KoaMiddleware[];
    validators?: KoaMiddleware[];
    controller: KoaMiddleware;
    requestTimeoutMs?: number;
    responseTimeoutMs?: number;
};

export type HttpRouteGroup = {
    name: string;
    prefix?: string | null;
    middleware?: KoaMiddleware[];
    routes: HttpRoute[];
    requestTimeoutMs?: number;
    responseTimeoutMs?: number;
};

export type KoaNext = () => Promise<any>;
export type ImageQuality = "good" | "better" | "best";
export type UpdateResult = {
    available: boolean;
    current: string;
    metadata: {
        version: string;
        release_date: string;
        release_name: string;
        release_notes: any;
    };
};
