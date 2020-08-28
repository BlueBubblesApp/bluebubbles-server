/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { BrowserRouter as Router, Route, HashRouter } from "react-router-dom";
import "./ViewContainer.css";
import { Switch } from "react-router";
import DashboardView from "./DashboardView/DashboardView";
import SettingsView from "./SettingsView/SettingsView";
import PreDashboardView from "./PreDashboardView/PreDashboardView";

class ViewContainer extends React.Component {
    render() {
        return (
            <div className="ViewContainer">
                <HashRouter>
                    <Switch
                        // atEnter={{ opacity: 0.1 }}
                        // atLeave={{ opacity: 0 }}
                        // atActive={{ opacity: 1 }}
                        // className="switch-wrapper"
                    >
                        <Route exact path="/predashboard" component={PreDashboardView}>
                            <PreDashboardView />
                        </Route>
                        <Route exact path="/" component={DashboardView}>
                            <DashboardView />
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
