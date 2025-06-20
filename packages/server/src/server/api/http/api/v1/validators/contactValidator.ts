import { BadRequest } from "../responses/errors";
import { Next } from "koa";
import { RouterContext } from "koa-router";
import { isEmpty, isNotEmpty } from "@server/helpers/utils";
import fs from "fs";

export class ContactValidator {
    static async validateUpdate(ctx: RouterContext, next: Next) {
        const { body } = ctx.request;
        // For single contact update (PUT /contact/:id)
        // We need an ID from the URL and update data in the body
        if (ctx.params.id) {
            if (isEmpty(body)) {
                throw new BadRequest({ error: "Request body is required for contact update!" });
            }

            return await next();
        }
        
        // For batch update (PUT /contact)
        // We need an array of contacts with id and update data
        if (!Array.isArray(body)) {
            throw new BadRequest({ error: "Request body must be an array for batch contact updates!" });
        }

        for (const item of body) {
            if (!item.id && !item.externalId) {
                throw new BadRequest({ error: "Each contact update must include either an 'id' or 'externalId' field!" });
            }
            
            // Ensure there's at least one field to update
            const hasUpdateFields = isNotEmpty(item.firstName) || 
                isNotEmpty(item.lastName) || 
                isNotEmpty(item.displayName) ||
                item.externalId !== undefined ||
                (Array.isArray(item.phoneNumbers) && item.phoneNumbers.length > 0) ||
                (Array.isArray(item.emails) && item.emails.length > 0) ||
                item.avatar !== undefined;
                
            if (!hasUpdateFields) {
                throw new BadRequest({ error: "Each contact update must include at least one field to update!" });
            }
        }

        return await next();
    }

    static async validateDelete(ctx: RouterContext, next: Next) {
        // If there's an ID in the URL, we don't need to validate the body
        if (ctx.params.id) {
            return await next();
        }
        
        // For batch delete operations
        const { body } = ctx.request;
        if (!Array.isArray(body)) {
            throw new BadRequest({ error: "Request body must be an array for batch contact deletions!" });
        }
        
        if (body.length === 0) {
            throw new BadRequest({ error: "Request body cannot be empty for batch contact deletions!" });
        }
        
        for (const item of body) {
            if (!item.id && !item.externalId) {
                throw new BadRequest({ error: "Each contact deletion must include either an 'id' or 'externalId' field!" });
            }
        }
        
        return await next();
    }

    static async validateImportVcf(ctx: RouterContext, next: Next) {
        const { files } = ctx.request;

        // Check if a VCF file was provided
        const vcfFile = files?.vcf as any;
        if (!vcfFile) {
            throw new BadRequest({ error: "VCF file is required! Upload using multipart/form-data with field name 'vcf'" });
        }
        
        // Check if file has content
        if (vcfFile.size === 0) {
            throw new BadRequest({ error: "VCF file is empty!" });
        }
        
        // Check file type
        const fileName = vcfFile.name.toLowerCase();
        if (!fileName.endsWith('.vcf') && !fileName.endsWith('.vcard')) {
            throw new BadRequest({ error: "File must be a valid VCF or vCard file (.vcf or .vcard extension)" });
        }
        
        // Check if file exists at the temp location
        if (!fs.existsSync(vcfFile.path)) {
            throw new BadRequest({ error: "Failed to upload VCF file" });
        }
        
        return await next();
    }
}
