import path from "path";
import { BrowserWindow, HandlerDetails, shell } from "electron";
import { Window } from ".";
import { Server } from "@server";
import { FirebaseOAuthWindow } from "@windows/FirebaseOAuthWindow";
import { ContactsOAuthWindow } from "./ContactsOAuthWindow";

export class AppWindow extends Window {
    private arguments: Record<string, any> = {};

    private static self: AppWindow;

    private constructor() {
        super();
    }

    public static getInstance(): AppWindow {
        if (!AppWindow.self) {
            AppWindow.self = new AppWindow();
        }

        return AppWindow.self;
    }

    setArguments(args: Record<string, any>): AppWindow {
        this.arguments = args;
        return this;
    }

    build(): AppWindow {
        const headless = (Server().repo?.getConfig("headless") as boolean) ?? false;
        if (headless) {
            Server().log("Headless mode enabled, skipping window creation...");
            return;
        }

        this.instance = new BrowserWindow({
            title: "BlueBubbles Server",
            useContentSize: true,
            width: 1080,
            minWidth: 850,
            height: 750,
            minHeight: 600,
            webPreferences: {
                nodeIntegration: true, // Required in new electron version
                contextIsolation: false // Required or else we get a `global` is not defined error
            }
        });

        if (process.env.NODE_ENV === "development") {
            process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = "1"; // eslint-disable-line require-atomic-updates
            this.instance.loadURL(`http://localhost:3000`);
        } else {
            this.instance.loadURL(`file://${path.join(__dirname, "index.html")}`);
        }

        // Register the event handlers
        this.registerEventHandlers();

        // Set the new window in the Server()
        Server(this.arguments, this.instance);

        return this;
    }

    registerEventHandlers() {
        this.instance.on("closed", () => {
            this.instance = null;
        });

        // Prevent the title from being changed from BlueBubbles
        this.instance.on("page-title-updated", evt => {
            evt.preventDefault();
        });

        // Make links open in the browser
        this.instance.webContents.setWindowOpenHandler((details: HandlerDetails) => {
            if (details.url.startsWith("https://accounts.google.com/o/oauth2/v2/auth")) {
                if (details.url.includes("type=contacts")) {
                    ContactsOAuthWindow.getInstance(details.url).build();
                } else if (details.url.includes("type=firebase")) {
                    FirebaseOAuthWindow.getInstance(details.url).build();
                }   
            } else {
                shell.openExternal(details.url);
            }

            return { action: "deny" };
        });

        // Hook onto when we load the UI
        this.instance.webContents.on("dom-ready", async () => {
            Server().uiLoaded = true;

            if (!this.instance.webContents.isDestroyed()) {
                this.instance.webContents.send("config-update", Server().repo.config);
            }
        });

        // Hook onto when the UI finishes loading
        this.instance.webContents.on("did-finish-load", async () => {
            Server().uiLoaded = true;
        });

        // Hook onto when the UI fails to load
        this.instance.webContents.on(
            "did-fail-load",
            async (event, errorCode, errorDescription, validatedURL, frameProcessId, frameRoutingId) => {
                Server().uiLoaded = false;
                Server().log(`Failed to load UI! Error: [${errorCode}] ${errorDescription}`, "error");
            }
        );

        // Hook onto when the renderer process crashes
        this.instance.webContents.on("render-process-gone", async (event, details) => {
            Server().uiLoaded = false;
            Server().log(`Renderer process crashed! Error: [${details.exitCode}] ${details.reason}`, "error");
        });

        // Hook onto when the webcontents are destroyed
        this.instance.webContents.on("destroyed", async () => {
            Server().uiLoaded = false;
            Server().log(`Webcontents were destroyed.`, "debug");
        });

        // Hook onto when there is a preload error
        this.instance.webContents.on("preload-error", async (event, preloadPath, error) => {
            Server().log(`A preload error occurred: Error: ${error.message}.`, "error");
        });
    }
}
