/* eslint-disable react/no-array-index-key */
/* eslint-disable class-methods-use-this */
/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer } from "electron";
import "./DebugView.css";
import TopNav from "@renderer/components/TopNav/TopNav";
import LeftStatusIndicator from "../DashboardView/LeftStatusIndicator/LeftStatusIndicator";

interface State {
    config: any;
    showDebug: boolean;
}

interface Props {
    logs: any[];
}

class SettingsView extends React.Component<Props, State> {
    constructor(props: Props) {
        super(props);

        this.state = {
            config: null,
            showDebug: false
        };
    }

    async componentDidMount() {
        const currentTheme = await ipcRenderer.invoke("get-current-theme");
        await this.setTheme(currentTheme.currentTheme);
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
        let filteredLogs = this.props.logs ?? [];
        if (!this.state.showDebug) {
            filteredLogs = filteredLogs.filter(item => item.type !== "debug");
        }

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
                        {filteredLogs.length === 0 ? (
                            <div className="aLogRow">
                                <p>No logs to show! They will be streamed here in real-time.</p>
                            </div>
                        ) : (
                            <>
                                {filteredLogs.map((row, index) => (
                                    <div key={index} className="aLogRow">
                                        <p>{row.log.message || "N/A"}</p>
                                        <p className="aLogTimestamp">{(row.timestamp as Date).toLocaleTimeString()}</p>
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
