import * as path from "path";
import * as fs from "fs";
import * as x509 from "@peculiar/x509";
import { pki, md } from "node-forge";

import { ServerConfigChange } from "@server/databases/server";
import { Server } from "@server";
import { FileSystem } from "@server/fileSystem";
import { certSubject, validForDays, millisADay } from "./constants";
import { onlyAlphaNumeric } from "@server/helpers/utils";
import { Loggable, getLogger } from "@server/lib/logging/Loggable";
import { ProxyServices } from "@server/databases/server/constants";

export class CertificateService extends Loggable {
    tag = "CertificateService";

    static get usingCustomPaths(): boolean {
        const cliCert = Server().args["cert-path"];
        const cliKey = Server().args["key-path"];
        return !!(cliCert && cliKey);
    }

    static get certPath(): string {
        const cliPath = Server().args["cert-path"];
        return cliPath ?? path.join(FileSystem.certsDir, "server.pem");
    }

    static get keyPath(): string {
        const cliPath = Server().args["key-path"];
        return cliPath ?? path.join(FileSystem.certsDir, "server.key");
    }

    static get expirationPath(): string {
        return path.join(FileSystem.certsDir, "expiration.txt");
    }

    static start() {
        // Listen for config changes
        CertificateService.createListener();

        // See if we need to refresh the certificate
        CertificateService.refreshCertificate();
    }

    private static refreshCertificate() {
        const log = getLogger("CertificateService");

        // Don't refresh the certificate if the user specified a custom path
        if (CertificateService.usingCustomPaths) return;

        let shouldRefresh = false;

        // If the file doesn't exist, definitely refresh it
        if (!CertificateService.certificateExists()) {
            shouldRefresh = true;
        }

        // If we have the certificate, check if it's expired
        if (!shouldRefresh) {
            try {
                const pem = fs.readFileSync(CertificateService.certPath, { encoding: "utf-8" });
                const now = new Date().getTime();
                if (pem.includes("BEGIN EC PRIVATE KEY")) {
                    const cert = new x509.X509Certificate(pem);
                    if (now > cert.notAfter.getTime()) {
                        shouldRefresh = true;
                    }
                } else {
                    const cert = pki.certificateFromPem(pem);
                    if (now > cert.validity.notAfter.getTime()) {
                        shouldRefresh = true;
                    }
                }
            } catch (ex: any) {
                log.warn("Failed to read certificate expiration! It may have been modified.");
                log.warn(`Error: ${ex?.message ?? ex ?? "Unknown Error"}`);
                shouldRefresh = true;
            }
        }

        // If the certificate doesn't exist, create it
        if (shouldRefresh) {
            log.info("Certificate doesn't exist or is expired! Regenerating...");
            CertificateService.generateCertificate();
            Server().httpService.restart();
        }
    }

    private static createListener() {
        Server().on("config-update", (args: ServerConfigChange) => CertificateService.handleConfigUpdate(args));
    }

    private static certificateExists() {
        return fs.existsSync(CertificateService.certPath) && fs.existsSync(CertificateService.keyPath);
    }

    private static removeCertificate() {
        // Don't remove the certificate if the user specified a custom path
        if (CertificateService.usingCustomPaths) return;

        fs.unlinkSync(CertificateService.certPath);
        fs.unlinkSync(CertificateService.keyPath);
    }

    static handleConfigUpdate({ prevConfig, nextConfig }: ServerConfigChange): Promise<void> {
        const log = getLogger("CertificateService");

        if (
            prevConfig.password === nextConfig.password &&
            onlyAlphaNumeric(nextConfig.proxy_service as string).toLowerCase() !== onlyAlphaNumeric(ProxyServices.DynamicDNS) &&
            onlyAlphaNumeric(prevConfig.proxy_service as string).toLowerCase() !==
                onlyAlphaNumeric(nextConfig.proxy_service as string).toLowerCase()
        )
            return;

        if (prevConfig.password !== nextConfig.password) {
            log.info("Password changed, generating new certificate");
            CertificateService.generateCertificate();
            Server().httpService.restart();
        } else if (
            onlyAlphaNumeric(prevConfig.proxy_service as string).toLowerCase() !==
                onlyAlphaNumeric(nextConfig.proxy_service as string).toLowerCase() &&
            onlyAlphaNumeric(nextConfig.proxy_service as string).toLowerCase() === onlyAlphaNumeric(ProxyServices.DynamicDNS)
        ) {
            log.info("Proxy service changed to Dynamic DNS. Refreshing certificate");
            CertificateService.refreshCertificate();
            Server().httpService.restart();
        }
    }

    static generateCertificate() {
        // Don't generate a certificate if the user specified a custom path
        if (CertificateService.usingCustomPaths) return;

        // Generate a keypair and create an X.509v3 certificate
        const keys = pki.rsa.generateKeyPair(2048);

        // Create the certificate
        const cert = pki.createCertificate();
        cert.publicKey = keys.publicKey;

        // Calculate expiration
        const now = new Date().getTime();
        const expiration = new Date(now + validForDays * millisADay);

        // Fill in the required fields
        cert.serialNumber = "01";
        cert.validity.notBefore = new Date();
        cert.validity.notAfter = expiration;
        cert.setSubject(certSubject);
        cert.setIssuer(certSubject);

        // self-sign certificate
        cert.sign(keys.privateKey, md.sha256.create());

        // Remove the old certificate if they exist
        if (CertificateService.certificateExists()) {
            CertificateService.removeCertificate();
        }

        // Convert a Forge certificate to PEM
        const pem = pki.certificateToPem(cert);
        const key = pki.privateKeyToPem(keys.privateKey);
        fs.writeFileSync(CertificateService.certPath, pem);
        fs.writeFileSync(CertificateService.keyPath, key);
    }
}
