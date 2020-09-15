import * as React from "react";
import * as ReactDOM from "react-dom";
import { ipcRenderer } from "electron";
import { HashRouter as Router } from "react-router-dom";
import ViewContainer from "./components/ViewContainer/ViewContainer";

import "./app.css";

// Create main element
const mainElement = document.createElement("div");
mainElement.classList.add("root");
document.body.appendChild(mainElement);

const render = () => {
    ReactDOM.render(
        <React.StrictMode>
            <ViewContainer />
        </React.StrictMode>,
        mainElement
    );
};

ipcRenderer.on("theme-update", (event, arg) => {
    const themedItems = document.querySelectorAll("[data-theme]");

    themedItems.forEach(item => {
        item.setAttribute("data-theme", arg);
    });
    // document.documentElement.setAttribute("data-theme", arg)
});

render();
