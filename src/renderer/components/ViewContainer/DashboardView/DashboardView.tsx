/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { Link } from "react-router-dom";
import TopNav from "./TopNav/TopNav";
import LeftStatusIndicator from "./LeftStatusIndicator/LeftStatusIndicator";
import StatBox from "./StatBox";

import "./DashboardView.css";

class DashboardView extends React.Component {
    render() {
        return (
            <div id="DashboardView">
                <TopNav />
                <div id="dashboardLowerContainer">
                    <LeftStatusIndicator />
                    <div id="rightMainContainer">
                        <div id="connectionStatusContainer">
                            <div id="connectionStatusLeft">
                                <h1 className="secondaryTitle">Connection</h1>
                                <h3 className="tertiaryTitle">Server Address: <div className="infoField"><p className="infoFieldText">https://adkj445asdsad.ngrok.io</p></div></h3>
                                <h3 className="tertiaryTitle">Server Port:<div className="infoField"><p className="infoFieldText">3000</p></div></h3>
                            </div>
                            <div id="connectionStatusRight">
                                qr code
                            </div>
                        </div>
                        <div id="statisticsContainer">
                            <h1 className="secondaryTitle">Statistics</h1>
                            <div id="statBoxesContainer">
                                <div className="aStatBoxRow">
                                    <StatBox title={"All Time"} stat={"8.5k"}/>
                                    <StatBox title={"Top Group"} stat={"BlueBubbles Is Awesome"} middle={true}/>
                                    <StatBox title={"Best Friend"} stat={"8.5k"}/>
                                </div>
                                <div className="aStatBoxRow">
                                    <StatBox title={"Last 24 Hours"} stat={"142"}/>
                                    <StatBox title={"Pictures"} stat={"426"} middle={true}/>
                                    <StatBox title={"Videos"} stat={"16"}/>
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            </div>
        );
    }
}

export default DashboardView;
