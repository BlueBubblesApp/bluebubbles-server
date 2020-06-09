/* eslint-disable react/no-array-index-key */
import * as React from "react";
// nodejs library that concatenates classes
import classNames from "classnames";
// nodejs library to set properties for components

// material-ui components
import withStyles from "@material-ui/core/styles/withStyles";
import Tabs from "@material-ui/core/Tabs";
import Tab from "@material-ui/core/Tab";
// core components
import Card from "../Card/Card";
import CardBody from "../Card/CardBody";
import CardHeader from "../Card/CardHeader";

import customTabsStyle from "../../assets/jss/material-dashboard-react/components/customTabsStyle";

interface Props {
    classes: any;
    headerColor: any;
    plainTabs?: any;
    tabs: any;
    title: any;
    rtlActive?: any;
}

interface State {
    value: number;
}

class CustomTabs extends React.Component<Props, State> {
    constructor(props: Props) {
        super(props);
        this.state = {
            value: 0
        };
        this.handleChange = this.handleChange.bind(this);
    }

    handleChange = (event: any, value: number) => {
        this.setState({ value });
    };

    render() {
        const { classes, headerColor, plainTabs, tabs, title, rtlActive } = this.props;
        const cardTitle = classNames({
            [classes.cardTitle]: true,
            [classes.cardTitleRTL]: rtlActive
        });
        return (
            <Card plain={plainTabs}>
                <CardHeader color={headerColor} plain={plainTabs}>
                    {title !== undefined ? <div className={cardTitle}>{title}</div> : null}
                    <Tabs
                        value={this.state.value}
                        onChange={this.handleChange}
                        classes={{
                            root: classes.tabsRoot,
                            indicator: classes.displayNone,
                            scrollButtons: classes.displayNone
                        }}
                        variant="scrollable"
                        scrollButtons="auto"
                    >
                        {tabs.map((prop: any, key: any) => {
                            let icon = {};
                            if (prop.tabIcon) {
                                icon = {
                                    icon: <prop.tabIcon />
                                };
                            }
                            return (
                                <Tab
                                    classes={{
                                        root: classes.tabRootButton,
                                        // labelContainer: classes.tabLabelContainer,
                                        // label: classes.tabLabel,
                                        selected: classes.tabSelected,
                                        wrapper: classes.tabWrapper
                                    }}
                                    key={key}
                                    label={prop.tabName}
                                    {...icon}
                                />
                            );
                        })}
                    </Tabs>
                </CardHeader>
                <CardBody>
                    {tabs.map((prop: any, key: any) => {
                        if (key === this.state.value) {
                            return <div key={key}>{prop.tabContent}</div>;
                        }
                        return null;
                    })}
                </CardBody>
            </Card>
        );
    }
}

export default withStyles(customTabsStyle)(CustomTabs);
