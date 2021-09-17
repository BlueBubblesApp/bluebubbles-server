import { Next } from "koa";
import { RouterContext } from "koa-router";

export class UiRouter {
    static async index(ctx: RouterContext, _: Next) {
        ctx.status = 200;
        ctx.body = `
            <html>
                <title>BlueBubbles Server</title>
                <body>
                    <h4>Welcome to the BlueBubbles Server landing page!</h4>
                </body>
            </html>
        `;
    }
}
