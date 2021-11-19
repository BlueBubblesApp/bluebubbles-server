import { Next } from "koa";
import { RouterContext } from "koa-router";
import { HTML } from "../responses/success";

export class UiRouter {
    static async index(ctx: RouterContext, _: Next) {
        return new HTML(
            ctx,
            `
            <html>
                <title>BlueBubbles Server</title>
                <body>
                    <h4>Welcome to the BlueBubbles Server landing page!</h4>
                </body>
            </html>
        `
        ).send();
    }
}
