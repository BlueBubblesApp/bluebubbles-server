/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { BrowserRouter as Router, Route, HashRouter } from "react-router-dom";
import "./ViewContainer.css";
import { Switch } from "react-router";
import DashboardView from "./DashboardView/DashboardView";
import DebugView from "./DebugView/DebugView";
import SettingsView from "./SettingsView/SettingsView";
import DevicesView from "./DevicesView/DevicesView";
import PreDashboardView from "./PreDashboardView/PreDashboardView";

class ViewContainer extends React.Component {
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
                            <DebugView />
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
