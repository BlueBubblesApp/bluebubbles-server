/* eslint-disable react/prefer-stateless-function */
import { ipcRenderer } from "electron";
import * as React from "react";

import { Route, HashRouter } from "react-router-dom";
import { Switch } from "react-router";

import DashboardView from "./DashboardView/DashboardView";
import DebugView from "./DebugView/DebugView";
import SettingsView from "./SettingsView/SettingsView";
import DevicesView from "./DevicesView/DevicesView";
import PreDashboardView from "./PreDashboardView/PreDashboardView";

import "./ViewContainer.css";

interface State {
    logs: any[];
}

const MAX_LENGTH = 25;

class ViewContainer extends React.Component<unknown, State> {
    constructor(props: unknown) {
        super(props);

        this.state = {
            logs: []
        };
    }

    async componentDidMount() {
        ipcRenderer.on("new-log", (event: any, data: any) => {
            // Build the new log
            // Insert the newest log at the top of the list
            let newLog = [{ log: data, timestamp: new Date() }, ...this.state.logs];

            // Make sure there are only MAX_LENGTH logs in the list
            newLog = newLog.slice(0, MAX_LENGTH);

            // Set the new logs
            this.setState({ logs: newLog });
        });
    }

    render() {
        return (
            <div className="ViewContainer">
                <HashRouter>
                    <Switch>
                        <Route exact path="/" component={PreDashboardView}>
                            <PreDashboardView />
                        </Route>
                        <Route exact path="/dashboard" component={DashboardView}>
                            <DashboardView />
                        </Route>
                        <Route exact path="/debug" component={DebugView}>
                            <DebugView logs={this.state.logs} />
                        </Route>
                        <Route exact path="/devices" component={DevicesView}>
                            <DevicesView />
                        </Route>
                        <Route path="/settings" component={SettingsView}>
                            <SettingsView />
                        </Route>
                    </Switch>
                </HashRouter>
            </div>
        );
    }
}

export default ViewContainer;
