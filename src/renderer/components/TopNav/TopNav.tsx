/* eslint-disable class-methods-use-this */
/* eslint-disable max-len */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import { Link } from "react-router-dom";
import "./TopNav.css";

interface State {
    notificationsOpen: boolean;
}

interface Props {
    header: string;
}

class TopNav extends React.Component<Props, State> {
    constructor(props: Readonly<Props>) {
        super(props);

        this.state = {
            // eslint-disable-next-line react/no-unused-state
            notificationsOpen: false
        };
    }

    // eslint-disable-next-line @typescript-eslint/no-empty-function
    handleOpenNotifications() {}

    render() {
        return (
            <div id="settingsTopNav">
                <div id="settingsTopLeftNav">
                    <Link id="dashboardIconLink" to="/dashboard">
                        <svg id="dashboardIcon" viewBox="0 0 206.108 206.108">
                            <path
                                d="M152.774,69.886H30.728l24.97-24.97c3.515-3.515,3.515-9.213,0-12.728c-3.516-3.516-9.213-3.515-12.729,0L2.636,72.523
        c-3.515,3.515-3.515,9.213,0,12.728l40.333,40.333c1.758,1.758,4.061,2.636,6.364,2.636c2.303,0,4.606-0.879,6.364-2.636
        c3.515-3.515,3.515-9.213,0-12.728l-24.97-24.97h122.046c19.483,0,35.334,15.851,35.334,35.334s-15.851,35.334-35.334,35.334H78.531
        c-4.971,0-9,4.029-9,9s4.029,9,9,9h74.242c29.408,0,53.334-23.926,53.334-53.334S182.182,69.886,152.774,69.886z"
                            />
                        </svg>
                    </Link>
                    <h1>{this.props.header}</h1>
                </div>
            </div>
        );
    }
}

export default TopNav;
