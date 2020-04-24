/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import {
    TextField,
    LinearProgress,
    Typography,
    Button,
    IconButton
} from "@material-ui/core";

interface Props {
    classes: any;
}

interface State {
    devices: any[];
}

class Dashboard extends React.Component<Props, State> {
    state: State = {
        devices: []
    };

    async componentDidMount() {
        await this.refreshDevices();
    }

    async refreshDevices() {
        this.setState({
            devices: await ipcRenderer.invoke("get-devices")
        });
    }

    render() {
        const { classes } = this.props;
        const { devices } = this.state;

        return (
            <section className={classes.root}>
                <Typography variant="h3">
                    Welcome!
                </Typography>
                <Typography variant="subtitle2">
                    This is the BlueBubble Dashboard. You'll be to see the status of your server,
                    as well as some cool statistics about your iMessages!
                </Typography>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {},
        header: {
            fontWeight: 400,
            marginBottom: "1em"
        }
    });

export default withStyles(styles)(Dashboard);
