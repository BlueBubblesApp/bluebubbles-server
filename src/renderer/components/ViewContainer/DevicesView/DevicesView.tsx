/* eslint-disable react/no-array-index-key */
/* eslint-disable class-methods-use-this */
/* eslint-disable jsx-a11y/label-has-associated-control */
/* eslint-disable max-len */
/* eslint-disable react/no-unused-state */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { ipcRenderer } from "electron";
import TopNav from "@renderer/components/TopNav/TopNav";
import LeftStatusIndicator from "../DashboardView/LeftStatusIndicator/LeftStatusIndicator";

import "./DevicesView.css";

interface State {
    config: any;
    devices: any[];
}

const MAX_LENGTH = 25;

class SettingsView extends React.Component<unknown, State> {
    constructor(props: unknown) {
        super(props);

        this.state = {
            config: null,
            devices: []
        };
    }

    async componentDidMount() {
        const currentTheme = await ipcRenderer.invoke("get-current-theme");
        await this.setTheme(currentTheme.currentTheme);
        await this.refreshDevices();
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

    async refreshDevices() {
        this.setState({
            devices: await ipcRenderer.invoke("get-devices")
        });
    }

    render() {
        return (
            <div id="SettingsView" data-theme="light">
                <TopNav header="Devices" />
                <div id="settingsLowerContainer">
                    <LeftStatusIndicator />
                    <div id="settingsMainRightContainer">
                        <h3 className="largeSettingTitle">Manage Devices</h3>
                        <div id="devicesHeadings">
                            <h1>Device Name</h1>
                            <h1>Identifier</h1>
                        </div>
                        {this.state.devices.length === 0 ? (
                            <p className="aDeviceRow" style={{ marginBottom: "25px" }}>
                                No devices registered!
                            </p>
                        ) : (
                            <>
                                {this.state.devices.map(row => (
                                    <div className="aDeviceRow" key={row.identifier}>
                                        <p>{row.name || "N/A"}</p>
                                        <p id="deviceIdentifier">{row.identifier}</p>
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
