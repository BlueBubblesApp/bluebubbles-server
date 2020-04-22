/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";
import { Typography, Button } from "@material-ui/core";

import { Config } from "@renderer/variables/types";
import { TextField, LinearProgress } from "@material-ui/core";
interface Props {
    config: Config
    classes: any;
}

interface State {
    port: string;
    frequency: string;
}

class Dashboard extends React.Component<Props, State> {
    state: State = {
        port: String(this.props.config?.socket_port || ""),
        frequency: String(this.props.config?.poll_frequency || "")
    }
    
    componentWillReceiveProps(nextProps: Props) {
        this.setState({
            port: String(nextProps.config?.socket_port || ""),
            frequency: String(nextProps.config?.poll_frequency || "")
        });
    }

    saveConfig = async () => {
        console.log("sending...")
        const res = await ipcRenderer.invoke("set-config", {
            poll_frequency: this.state.frequency,
            socket_port: this.state.port
        });
        console.log(res)
    }

    handleChange = (e: React.ChangeEvent<HTMLTextAreaElement | HTMLInputElement>) => {
        const id = e.target.id;
        if (id === "port") this.setState({ port: e.target.value });
        if (id === "frequency") this.setState({ frequency: e.target.value });
    }

    render() {
        const { classes, config } = this.props;
        console.log(config)

        return (
            <section className={classes.root}>
                <Typography variant="h3" className={classes.header}>
                    Configuration
                </Typography>

                {!config ? (
                    <LinearProgress />
                ) : (
                    <form
                        className={classes.form}
                        noValidate
                        autoComplete="off"
                    >
                        <TextField
                            required
                            className={classes.field}
                            id="server-address"
                            label="Current Server Address"
                            variant="outlined"
                            value={config?.server_address}
                            disabled
                        />
                        <TextField
                            required
                            className={classes.field}
                            id="port"
                            label="Socket Port"
                            variant="outlined"
                            value={this.state.port}
                            onChange={(e) => this.handleChange(e)}
                        />
                        <TextField
                            required
                            id="frequency"
                            className={classes.field}
                            label="Poll Frequency (ms)"
                            value={this.state.frequency}
                            variant="outlined"
                            helperText="How often should we check for new messages?"
                            onChange={(e) => this.handleChange(e)}
                        />
                        <br />
                        <Button onClick={() => this.saveConfig()} color="secondary">Save</Button>
                    </form>
                )}
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {

        },
        header: {
            fontWeight: 300,
            marginBottom: "1em"
        },
        form: {
            display: "flex",
            flexDirection: "column",
            justifyContent: "center"
        },
        field: {
            marginBottom: "1.5em"
        }
    });

export default withStyles(styles)(Dashboard);
