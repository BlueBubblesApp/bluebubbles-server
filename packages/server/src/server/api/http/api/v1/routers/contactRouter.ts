import { RouterContext } from "koa-router";
import { Next } from "koa";

import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/interfaces/contactInterface";
import { Success } from "../responses/success";
import { Contact } from "@server/databases/server/entity";
import { parseWithQuery } from "../utils";
import { BadRequest } from "../responses/errors";

export class ContactRouter {
    private static isAddressObject(data: any): boolean {
        return (
            data &&
            typeof data === "object" &&
            !Array.isArray(data) &&
            (Object.keys(data).includes("firstName") || Object.keys(data).includes("displayName"))
        );
    }

    static async get(ctx: RouterContext, _: Next) {
        const extraProps = parseWithQuery(ctx.request.query?.extraProperties as string)
        const contacts = await ContactInterface.getAllContacts(extraProps);
        return new Success(ctx, { data: contacts }).send();
    }

    static async query(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;
        const addresses = body?.addresses ?? [];
        const extraProps = parseWithQuery(body?.extraProperties ?? [], false);

        if (!Array.isArray(addresses)) {
            throw new BadRequest({ 'error': 'Addresses must be an array of strings!' });
        }

        let res = [];
        if (isEmpty(addresses)) {
            res = await ContactInterface.getAllContacts(extraProps);
        } else {
            res = await ContactInterface.queryContacts(addresses, extraProps);
        }

        return new Success(ctx, { data: res }).send();
    }

    static async create(ctx: RouterContext, _: Next) {
        let { body } = ctx.request;

        // Make the body into an array if it isn't. This is so
        // we can seamlessly iterate over all the objects
        if (typeof body === "object" && !Array.isArray(body)) {
            body = [body];
        }

        const contacts: Contact[] = [];
        const errors: any[] = [];
        for (const item of body) {
            if (!ContactRouter.isAddressObject(item)) {
                errors.push({
                    entry: item,
                    error: "Input address object is not contain the required information!"
                });

                continue;
            }

            try {
                contacts.push(
                    await ContactInterface.createContact({
                        firstName: item.firstName ?? '',
                        lastName: item?.lastName ?? '',
                        displayName: item?.displayName ?? '',
                        phoneNumbers: item?.phoneNumbers ?? [],
                        emails: item?.emails ?? [],
                        avatar: item?.avatar ?? null,
                        updateEntry: true
                    })
                );
            } catch (ex: any) {
                console.log(ex);
                errors.push({
                    entry: item,
                    error: ex?.message ?? String(ex)
                });
            }
        }

        const output: any = { data: ContactInterface.mapContacts(contacts, "db") };
        if (isNotEmpty(errors)) {
            output.metadata = {};
            output.metadata.errors = errors;
        }

        return new Success(ctx, output).send();
    }
}
