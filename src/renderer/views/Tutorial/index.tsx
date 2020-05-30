/* eslint-disable */
import * as React from "react";
import { ipcRenderer } from "electron";
import { withRouter, Redirect } from "react-router-dom";

import {
    createStyles,
    Theme,
    withStyles,
    StyleRules
} from "@material-ui/core/styles";

import {
    Typography,
    Button
} from "@material-ui/core";

import HowItWorks from "./steps/HowItWorks";
import Permissions from "./steps/Permissions";
import FCMServer from "./steps/FCMServer";
import FCMClient from "./steps/FCMClient";
import QRCode from "./steps/QRCode";

const stepMap: { [key: number]: any } = {
    0: {
        component: HowItWorks,
        text: "How it Works"
    },
    1: {
        component: Permissions,
        text: "Permissions"
    },
    2: {
        component: FCMServer,
        text: "Google FCM Service"
    },
    3: {
        component: FCMClient,
        text: "Google FCM Client"
    },
    4: {
        component: QRCode,
        text: "QRCode"
    }
};

interface Props {
    classes: any;
    config: any;
    history: any;
    location: any;
    match: any;
}

interface State {
    step: number;
}

class Tutorial extends React.Component<Props, State> {
    state: State = {
        step: 0
    };

    completeTutorial() {
        ipcRenderer.invoke("complete-tutorial");
        this.props.history.push("/welcome")
    }

    nextStep() {
        this.setState({step: this.state.step + 1});
    }

    lastStep() {
        this.setState({ step: this.state.step - 1 });
    }

    render() {
        const { classes, config } = this.props;
        const { step } = this.state;

        let tutorialIsDone = config?.tutorial_is_done;
        if (tutorialIsDone && Boolean(Number(tutorialIsDone))) {
            return <Redirect to="/welcome" />;
        }

        const CurrentStep = stepMap[step].component;
        const CurrentText = stepMap[step].text;

        return (
            <section className={classes.root}>
                <Typography variant="h3" className={classes.header}>
                    Tutorial
                </Typography>
                <Typography variant="subtitle1">
                    Welcome to the BlueBubbles Tutorial! Follow these steps to
                    learn how the server and ecosystem work!
                </Typography>
                <CurrentStep />
                <section className={classes.footer}>
                    {step < Object.keys(stepMap).length - 1 ? (
                        <Button
                            variant="outlined"
                            onClick={() => this.completeTutorial()}
                        >
                            Skip Tutorial
                        </Button>
                    ) : null}
                    <section>
                        {step > 0 ? (
                            <Button
                                variant="outlined"
                                onClick={() => this.lastStep()}
                            >{`Previous: ${stepMap[step - 1].text}`}</Button>
                        ) : null}

                        {step < Object.keys(stepMap).length - 1 ? (
                            <Button
                                variant="outlined"
                                onClick={() => this.nextStep()}
                                style={{ marginLeft: "1em" }}
                            >{`Next: ${stepMap[step + 1].text}`}</Button>
                        ) : (
                            <Button
                                variant="outlined"
                                onClick={() => this.completeTutorial()}
                                style={{ marginLeft: "1em" }}
                            >
                                {"Complete Tutorial"}
                            </Button>
                        )}
                    </section>
                </section>
            </section>
        );
    }
}

const styles = (theme: Theme): StyleRules<string, {}> =>
    createStyles({
        root: {},
        header: {
            fontWeight: 400
        },
        footer: {
            marginTop: "2em",
            display: "flex",
            flexDirection: "row",
            justifyContent: "space-between"
        }
    });

export default withStyles(styles)(withRouter(Tutorial));
