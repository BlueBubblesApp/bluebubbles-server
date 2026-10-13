import fs from "fs";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { HTML } from "../responses/success";
import { Server } from "@server";
import { isEmpty } from "@server/helpers/utils";

export class UiRouter {
    static async index(ctx: RouterContext, _: Next) {
        const landingPath = Server().repo.getConfig('landing_page_path') as string;
        if (isEmpty(landingPath)) {
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

        // See if the file path exists
        // if it doesn't, return a warning
        // if it does, return the file
        if (fs.existsSync(landingPath)) {
            return new HTML(ctx, fs.readFileSync(landingPath, 'utf8')).send();
        }

        return new HTML(
            ctx,
            `
                <html>
                    <title>BlueBubbles Server</title>
                    <body>
                        <h4>[WARNING] Custom landing page not found!</h4>
                    </body>
                </html>
            `
        ).send();
        
    }
}
