import "reflect-metadata";
import { app, BrowserWindow } from "electron";
import * as path from "path";
import * as url from "url";

import { DatabaseRepository } from "@server/api/imessage";
// import { MessageListener } from "@server/api/imessage/database/listeners";
import { createDbConnection, createSockets } from "@server/index";
import { MessageListener } from "@server/api/imessage/listeners/messageListener";
import { Message } from "@server/api/imessage/entity/Message";

let win: BrowserWindow | null;

const installExtensions = async () => {
    const installer = require("electron-devtools-installer");
    const forceDownload = !!process.env.UPGRADE_EXTENSIONS;
    const extensions = ["REACT_DEVELOPER_TOOLS", "REDUX_DEVTOOLS"];

    return Promise.all(
        extensions.map((name) =>
            installer.default(installer[name], forceDownload)
        )
    ).catch(console.log); // eslint-disable-line no-console
};

const createWindow = async () => {
    if (process.env.NODE_ENV !== "production") {
        await installExtensions();
    }

    win = new BrowserWindow({
        width: 800,
        height: 600,
        webPreferences: {
            nodeIntegration: true // Required in new electron version
        }
    });

    if (process.env.NODE_ENV !== "production") {
        process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = "1"; // eslint-disable-line require-atomic-updates
        win.loadURL(`http://localhost:2003`);
    } else {
        win.loadURL(
            url.format({
                pathname: path.join(__dirname, "index.html"),
                protocol: "file:",
                slashes: true
            })
        );
    }

    if (process.env.NODE_ENV !== "production") {
        // Open DevTools, see https://github.com/electron/electron/issues/12438 for why we wait for dom-ready
        win.webContents.once("dom-ready", () => {
            win!.webContents.openDevTools();
        });
    }

    win.on("closed", () => {
        win = null;
    });

    // Connect to the iMessage Chat Database
    const repo = new DatabaseRepository();
    await repo.initialize();

    /**
     * Create a connection to the config database and create the sockets
     */
    const connection = await createDbConnection();
    const server = createSockets(connection, repo);

    // Create a listener to listen for new messages
    const listener = new MessageListener(repo, 1000);
    listener.start();
    listener.on("new-entry", (item: Message) => {
        console.log(
            `New message from ${item.from.id}, sent to ${item.chats[0].chatIdentifier}`
        );

        server.emit("new-message", item);
    });
};

app.on("ready", createWindow);

app.on("window-all-closed", () => {
    if (process.platform !== "darwin") {
        app.quit();
    }
});

app.on("activate", () => {
    if (win === null) {
        createWindow();
    }
});
