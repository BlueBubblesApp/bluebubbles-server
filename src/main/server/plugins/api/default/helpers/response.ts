import type * as WS from "@trufflesuite/uws-js-unofficial";
import type { UpgradedHttp, UpgradedSocket } from "../types";

type ProtocolOpts = WS.HttpResponse | WS.WebSocket | UpgradedSocket;

export class Response {
    public static ok(res: WS.HttpResponse, data: any) {
        res.writeStatus("200 OK");
        Response.respond(res, { data });
    }

    public static created(res: WS.HttpResponse, data: any) {
        res.writeStatus("201 Created");
        Response.respond(res, { data });
    }

    public static badRequest(res: WS.HttpResponse, code: number, errors?: string[] | string) {
        res.writeStatus(`${code} Bad Request`);
        Response.respond(res, {
            code,
            message: "A bad request was made to the server",
            errors: Response.normalizeErrors(errors)
        });
    }

    public static notFound(res: WS.HttpResponse) {
        res.writeStatus(`404 Not Found`);
        Response.respond(res, {
            code: 404,
            message: "Endpoint does not exist"
        });
    }

    public static unauthorized(res: WS.HttpResponse, code = 401, errors?: string[] | string) {
        res.writeStatus(`${code} Unauthorized`);
        Response.respond(res, {
            code,
            message: "You do not have permisisons to access this endpoint.",
            errors: Response.normalizeErrors(errors)
        });
    }

    public static forbidden(res: WS.HttpResponse, code = 403, errors?: string[] | string) {
        res.writeStatus(`403 Forbidden`);
        Response.respond(res, {
            code,
            message: "You are forbidden from accessing this endpoint.",
            errors: Response.normalizeErrors(errors)
        });
    }

    public static error(res: WS.HttpResponse, code: number, errors?: string[] | string) {
        res.writeStatus(`${code} Internal Server Error`);
        Response.respond(res, {
            code,
            message: "A server error has occurred",
            errors: Response.normalizeErrors(errors)
        });
    }

    private static normalizeErrors(errors: string[] | string): string[] {
        if (!errors) return [];
        if (typeof errors === "string") return [errors];
        return errors;
    }

    private static isHttp(tbd: ProtocolOpts): tbd is WS.HttpResponse {
        if ((tbd as WS.HttpResponse).end) return true;
        return false;
    }

    private static isSocket(tbd: ProtocolOpts): tbd is WS.WebSocket {
        if ((tbd as WS.WebSocket).send) return true;
        return false;
    }

    private static isUpgradedSocket(tbd: ProtocolOpts): tbd is UpgradedSocket {
        if ((tbd as UpgradedSocket).plugin) return true;
        return false;
    }

    private static respond(res: ProtocolOpts, data: any): void {
        const json = JSON.stringify(data);
        if (Response.isHttp(res)) {
            res.writeHeader("Content-Type", "application/json");
            res.end(json);
        } else if (Response.isSocket(res)) {
            res.send(json);
        } else if (Response.isUpgradedSocket(res)) {
            (res as UpgradedSocket).send(json);
        }
    }
}
