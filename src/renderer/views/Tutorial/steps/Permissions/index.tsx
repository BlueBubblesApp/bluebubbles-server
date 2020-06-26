/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";

import { createStyles, Theme, withStyles, StyleRules } from "@material-ui/core/styles";
import { Config } from "@renderer/variables/types";

import Typography from "@material-ui/core/Typography";
import Button from "@material-ui/core/Button";

import CheckCircleOutlineIcon from "@material-ui/icons/CheckCircleOutline";
import HighlightOffIcon from "@material-ui/icons/HighlightOff";

import SecurityImage from "@renderer/assets/img/security.png";
import AccessImage from "@renderer/assets/img/access.png";

interface Props {
    config: Config;
    classes: any;
}

interface State {
    port: string;
    abPerms: string;
    fdPerms: string;
}

class Permissions extends React.Component<Props, State> {
    state: State = {
        port: String(this.props.config?.socket_port || ""),
        abPerms: "denied",
        fdPerms: "denied"
    };

    componentDidMount() {
        this.checkPermissions();
    }

    openPermissionPrompt = async () => {
        const res = await ipcRenderer.invoke("open_perms_prompt");
        console.log(res);
    };

    openAccessibilityPrompt = async () => {
        const res = await ipcRenderer.invoke("prompt_accessibility_perms");
        console.log(res);
    };

    checkPermissions = async () => {
        const res = await ipcRenderer.invoke("check_perms");
        this.setState({
            abPerms: res.abPerms,
            fdPerms: res.fdPerms
        });
    };

    render() {
        const { classes } = this.props;

        return (
            <section>
                <section className={classes.root}>
                    <Typography variant="h4" className={classes.header}>
                        Permissions
                    </Typography>
                    <Typography variant="subtitle2" className={classes.subtitle}>
                        In order for this server to work, it needs <i>Full Disk Access</i> as well as{" "}
                        <i>Accessibility Access</i>. This is because it needs to be able to access both the iMessage
                        chat database, as well as use accessibility features to interact with chats via the iMessage
                        Application. Without these permissions, the server will not be able to function fully.
                    </Typography>
                    {(this.state.abPerms === "authorized" && this.state.fdPerms == "authorized") || (
                        <section className={classes.iconBar}>
                            {this.state.fdPerms === "authorized" || (
                                <Button variant="outlined" onClick={() => this.openPermissionPrompt()}>
                                    Open Full Disk Prompt
                                </Button>
                            )}
                            &nbsp;
                            {this.state.abPerms === "authorized" || (
                                <Button variant="outlined" onClick={() => this.openAccessibilityPrompt()}>
                                    Open Accessibility Prompt
                                </Button>
                            )}
                        </section>
                    )}
                    <Typography variant="h5" className={classes.subtitle}>
                        Steps
                    </Typography>
                    <Typography variant="subtitle2" className={classes.subtitle}>
                        <strong>1.</strong> Open up System Preferences, and then open "Security &amp; Privacy"
                    </Typography>
                    <img src={SecurityImage} width="600px" alt="" />
                    <Typography variant="subtitle2" className={classes.subtitle}>
                        <strong>2.</strong> Unlock your settings, and add Full Disk Access permissions for the
                        BlueBubbles App. You can do this by clicking the '+' button and then selecting the BlueBubbles
                        App.
                    </Typography>
                    <Typography variant="subtitle2" className={classes.subtitle}>
                        <strong>3.</strong> Repeat <i>Step 2</i>, but for Accessibility
                    </Typography>
                    <img src={AccessImage} width="500px" alt="" />
                    <br />
                    <br />
                </section>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {
            marginTop: "0.5em"
        },
        header: {
            fontWeight: 400
        },
        subtitle: {
            marginTop: "0.5em",
            padding: "5px"
        },
        sub: {
            marginTop: "0.5em",
            paddingLeft: "25px",
            paddingRight: "25px"
        },
        iconBar: {
            display: "flex",
            flexDirection: "row",
            justifyContent: "center"
        }
    });

export default withStyles(styles)(Permissions);
