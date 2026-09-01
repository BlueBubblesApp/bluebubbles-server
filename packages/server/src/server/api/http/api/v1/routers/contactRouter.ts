import { RouterContext } from "koa-router";
import { Next } from "koa";

import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import { ContactInterface } from "@server/api/interfaces/contactInterface";
import { Success } from "../responses/success";
import { parseWithQuery } from "../utils";
import { BadRequest } from "../responses/errors";

export class ContactRouter {
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

        const res = await ContactInterface.queryContacts(addresses, extraProps);
        return new Success(ctx, { data: res }).send();
    }

    static async create(ctx: RouterContext, _: Next) {
        let { body } = ctx.request;

        // Make the body into an array if it isn't
        if (typeof body === "object" && !Array.isArray(body)) {
            body = [body];
        }

        const { contacts, errors } = await ContactInterface.batchCreateContacts(body);
        
        const output: any = { data: ContactInterface.mapContacts(contacts, "db") };
        if (isNotEmpty(errors)) {
            output.metadata = { errors };
        }

        if (isEmpty(output.data)) {
            output.message = "No contacts were created!";
        }

        return new Success(ctx, output).send();
    }
    
    static async update(ctx: RouterContext, _: Next) {
        const { body } = ctx.request;
        const singleContactId = ctx.params.id;
        let contactsToUpdate = [];
        
        // Handle single contact update (PUT /contact/:id)
        if (singleContactId) {
            contactsToUpdate = [{
                id: parseInt(singleContactId, 10),
                ...body
            }];
        } 
        // Handle batch update (PUT /contact)
        else {
            contactsToUpdate = body;
        }
        
        const { contacts, errors } = await ContactInterface.batchUpdateContacts(contactsToUpdate);
        
        const output: any = { data: ContactInterface.mapContacts(contacts, "db") };
        if (isNotEmpty(errors)) {
            output.metadata = { errors };
        }

        if (isEmpty(output.data)) {
            output.message = "No contacts were updated!";
        }
        
        return new Success(ctx, output).send();
    }

    static async findByExternalId(ctx: RouterContext, _: Next) {
        const externalId = ctx.params.externalId;
        if (!externalId) {
            throw new BadRequest({ error: 'External ID is required!' });
        }
        
        try {
            const contact = await ContactInterface.findDbContact({ externalId, throwError: false });
            if (!contact) {
                return new Success(ctx, { data: null }).send();
            }
            
            const extraProps = parseWithQuery(ctx.request.query?.extraProperties as string);
            const mappedContact = ContactInterface.mapContacts([contact], "db", { extraProps });
            
            return new Success(ctx, { data: mappedContact[0] }).send();
        } catch (ex: any) {
            throw new BadRequest({ error: ex?.message ?? String(ex) });
        }
    }
    
    static async delete(ctx: RouterContext, _: Next) {
        const contactId = ctx.params.id;
        
        try {
            // Delete a single contact by ID from the URL
            if (contactId) {
                await ContactInterface.deleteContact({ contactId: parseInt(contactId, 10) });
                return new Success(ctx, { 
                    message: `Contact with ID: ${contactId} deleted successfully` 
                }).send();
            }
            
            // Handle batch delete from request body
            const { body } = ctx.request;
            const { deletedIds, errors } = await ContactInterface.batchDeleteContacts(body);
            
            const output: any = { 
                message: `${deletedIds.length} contacts deleted successfully`,
                data: deletedIds
            };
            
            if (isNotEmpty(errors)) {
                output.metadata = { errors };
            }
            
            return new Success(ctx, output).send();
        } catch (ex: any) {
            throw new BadRequest({ error: ex?.message ?? String(ex) });
        }
    }

    static async importVcf(ctx: RouterContext, _: Next) {
        try {
            const { files } = ctx.request;
            const vcfFile = files?.vcf as any;
            
            if (!vcfFile) {
                throw new BadRequest({ error: 'VCF file is required!' });
            }
            
            // The file is already stored in a temp location (vcfFile.path)
            // We can use it directly with the ContactInterface
            const contacts = await ContactInterface.importFromVcf(vcfFile.path);
            
            // Map the imported contacts and prepare response
            const mappedContacts = ContactInterface.mapContacts(contacts, "db");
            const output: any = { 
                message: `${contacts.length} contacts imported successfully`,
                data: mappedContacts
            };
            
            if (contacts.length === 0) {
                output.message = "No contacts were imported. The VCF file may be empty or invalid.";
            }
            
            return new Success(ctx, output).send();
        } catch (ex: any) {
            throw new BadRequest({ error: ex?.message ?? String(ex) });
        }
    }
}
