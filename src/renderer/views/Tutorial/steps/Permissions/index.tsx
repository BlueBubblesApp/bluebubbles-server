/* eslint-disable */
import * as React from "react";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import { Typography } from "@material-ui/core";

import SecurityImage from "@renderer/assets/img/security.png";
import AccessImage from "@renderer/assets/img/access.png";

interface Props {
    classes: any;
}

interface State {}

class Permissions extends React.Component<Props, State> {
    render() {
        const { classes } = this.props;

        return (
            <section className={classes.root}>
                <Typography variant="h4" className={classes.header}>
                    Permissions
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    In order for this server to work, it needs{" "}
                    <i>Full Disk Access</i> as well as <i>Accessibility Access</i>.
                    This is because it needs to be able to access both the iMessage chat
                    database, as well as use accessibility features to interact with chats
                    via the iMessage Application. Without these permissions, the server will
                    not be able to function fully.
                </Typography>
                <Typography variant="h5" className={classes.subtitle}>
                    Steps
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>1.</strong> Open up System Preferences, and then
                    open "Security &amp; Privacy"
                </Typography>
                <img src={SecurityImage} width="600px" alt="" />
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>2.</strong> Unlock your settings, and add Full Disk Access
                    permissions for the BlueBubbles App. You can do this by clicking the '+'
                    button and then selecting the BlueBubbles App.
                </Typography>
                <Typography variant="subtitle2" className={classes.subtitle}>
                    <strong>3.</strong> Repeat <i>Step 2</i>, but for Accessibility
                </Typography>
                <img src={AccessImage} width="500px" alt="" />
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
            marginTop: "0.5em"
        }
    });

export default withStyles(styles)(Permissions);
