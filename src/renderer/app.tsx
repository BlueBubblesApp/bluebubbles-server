import * as React from "react";
import * as ReactDOM from "react-dom";
import { BrowserRouter as Router } from "react-router-dom";

// core components
import Admin from "./layouts/Admin";

// Create main element
const mainElement = document.createElement("div");
document.body.appendChild(mainElement);

const render = () => {
    ReactDOM.render(
        <Router>
            <Admin />
        </Router>,
        mainElement
    );
};

render();
