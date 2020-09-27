/* eslint-disable react/no-array-index-key */
/* eslint-disable class-methods-use-this */
/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer } from "electron";
import "./DebugView.css";
import * as Ago from "s-ago";
import TopNav from "@renderer/components/TopNav/TopNav";
import LeftStatusIndicator from "../DashboardView/LeftStatusIndicator/LeftStatusIndicator";

interface State {
    config: any;
    logs: any[];
    showDebug: boolean;
}

const MAX_LENGTH = 25;

class SettingsView extends React.Component<unknown, State> {
    constructor(props: unknown) {
        super(props);

        this.state = {
            config: null,
            logs: [],
            showDebug: false
        };
    }

    async componentDidMount() {
        const currentTheme = await ipcRenderer.invoke("get-current-theme");
        await this.setTheme(currentTheme.currentTheme);

        ipcRenderer.on("new-log", (event: any, data: any) => {
            if (!this.state.showDebug && data.type === "debug") return;

            // Build the new log
            let newLog = [...this.state.logs, { log: data, timestamp: new Date() }];

            // Make sure there are only MAX_LENGTH logs in the list
            newLog = newLog.slice(newLog.length - MAX_LENGTH < 0 ? 0 : newLog.length - MAX_LENGTH, newLog.length);

            // Set the new logs
            this.setState({ logs: newLog });
        });
    }

    async setTheme(currentTheme: string) {
        const themedItems = document.querySelectorAll("[data-theme]");

        if (currentTheme === "dark") {
            themedItems.forEach(item => {
                item.setAttribute("data-theme", "dark");
            });
        } else {
            themedItems.forEach(item => {
                item.setAttribute("data-theme", "light");
            });
        }
    }

    handleInputChange = async (e: any) => {
        const { id } = e.target;
        if (id === "toggleDebug") {
            const target = e.target as HTMLInputElement;
            this.setState({ showDebug: target.checked });
        }
    };

    invokeMain(event: string, args: any) {
        ipcRenderer.invoke(event, args);
    }

    render() {
        return (
            <div id="SettingsView" data-theme="light">
                <TopNav header="Debugging" />
                <div id="settingsLowerContainer">
                    <LeftStatusIndicator />
                    <div id="settingsMainRightContainer">
                        <h3 className="largeSettingTitle">
                            Debug Logs{" "}
                            <button id="clearLogsButton" onClick={() => this.invokeMain("purge-event-cache", null)}>
                                Clear Event Cache
                            </button>{" "}
                            <p>Show Debug Logs</p>
                            <input id="toggleDebug" onChange={e => this.handleInputChange(e)} type="checkbox" />
                        </h3>
                        <div id="logHeadings">
                            <h1>Log Message</h1>
                            <h1>Timestamp</h1>
                        </div>
                        {this.state.logs.length === 0 ? (
                            <div className="aLogRow">
                                <p>No logs. This page only shows logs while this page is open!</p>
                            </div>
                        ) : (
                            <>
                                {this.state.logs.map((row, index) => (
                                    <div key={index} className="aLogRow">
                                        <p>{row.log.message || "N/A"}</p>
                                        <p className="aLogTimestamp">{Ago(row.timestamp)}</p>
                                    </div>
                                ))}
                            </>
                        )}
                    </div>
                </div>
            </div>
        );
    }
}

export default SettingsView;
