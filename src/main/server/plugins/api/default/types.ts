import type * as WS from "@trufflesuite/uws-js-unofficial";
import type DefaultApiPlugin from "./index";
import type { Token } from "./database/entity";
import type { ApiDatabase } from "./database";

export type TokenData = {
    token: string;
    expires_in: number;
};

export type WsMiddleware = (res: WS.HttpResponse, req: WS.HttpRequest) => Promise<void>;

export type RequestData = {
    json: NodeJS.Dict<any>;
    params: NodeJS.Dict<string | string[]>;
    headers: NodeJS.Dict<string>;
};

export type UpgradedSocket = WS.WebSocket & {
    auth: Token;
    plugin: DefaultApiPlugin;
    json: NodeJS.Dict<any>;
    params: NodeJS.Dict<string | string[]>;
};

export type UpgradedHttp = WS.HttpRequest & {
    auth: Token;
    plugin: DefaultApiPlugin;
    json: NodeJS.Dict<any>;
    params: NodeJS.Dict<string | string[]>;
    headers: NodeJS.Dict<string>;
    hasEnded: boolean;
};

export type ClientWsRequest = {
    path: string;
    headers: { [key: string]: string | number };
    params: { [key: string]: string | number | boolean };
    data: any;
};

export enum WsRoute {
    NEW_MESSAGE = "notifications/new-message"
}
