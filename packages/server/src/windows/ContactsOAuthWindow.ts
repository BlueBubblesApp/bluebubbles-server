import { BrowserWindow } from "electron";
import { Window } from ".";
import { Server } from "@server";
import { ProgressStatus } from "@server/types";

export class ContactsOAuthWindow extends Window {
    private url: string = null;

    private static self: ContactsOAuthWindow;

    private constructor(url: string) {
        super();
        this.url = url;
    }

    public static getInstance(url: string): ContactsOAuthWindow {
        if (!ContactsOAuthWindow.self) {
            ContactsOAuthWindow.self = new ContactsOAuthWindow(url);
        } else {
            // Always use the latest URL. Each attempt generates a fresh PKCE
            // challenge that must match the server's current code verifier;
            // reusing a stale URL causes an "Invalid code verifier" error.
            ContactsOAuthWindow.self.url = url;
        }

        return ContactsOAuthWindow.self;
    }

    build(): ContactsOAuthWindow {
        // Create new Browser window
        if (this.instance && !this.instance.isDestroyed) this.instance.destroy();
        this.instance = new BrowserWindow({
            width: 800,
            height: 600,
            webPreferences: {
                nodeIntegration: true,
            }
        });

        this.instance.loadURL(this.url);
        this.instance.webContents.on("did-finish-load", () => {
            const url = this.instance.webContents.getURL();
            const callbackUrl = Server().oauthService?.callbackUrl;
            if (!callbackUrl || !url.startsWith(callbackUrl)) return;

            // Two possible flows:
            //  - Background sync (own client): authorization code in the query string (?code=...)
            //  - One-time sync (built-in client): access token in the URL fragment (#access_token=...)
            const params = new URL(url).searchParams;
            const code = params.get("code");
            const error = params.get("error");

            const hash = url.includes("#") ? url.split("#")[1] : "";
            const hashParams = new URLSearchParams(hash);
            const accessToken = hashParams.get("access_token");

            if (code) {
                Server().oauthService.handleContactsAuthCode(code);
            } else if (accessToken) {
                Server().oauthService.authToken = accessToken;
                Server().oauthService.expiresIn = Number.parseInt(hashParams.get("expires_in") ?? "3600");
                Server().oauthService.handleContactsSync();
            } else {
                // The user denied access or an error occurred.
                Server().oauthService.setStatus(error ? ProgressStatus.FAILED : ProgressStatus.NOT_STARTED);
                Server().oauthService.stop();
            }

            // Clear the window data
            this.instance.close();
            this.instance = null;
        });

        // On window close, if the oauth service is not in progress, stop it
        this.instance.on("close", () => {
            if (Server().oauthService?.status !== ProgressStatus.IN_PROGRESS) {
                Server().oauthService.stop();
            }
        });

        return this;
    }
}
