import * as React from "react";
import classnames from "classnames";
// @material-ui/core components
import withStyles from "@material-ui/core/styles/withStyles";
import Checkbox from "@material-ui/core/Checkbox";
import Tooltip from "@material-ui/core/Tooltip";
import IconButton from "@material-ui/core/IconButton";
import Table from "@material-ui/core/Table";
import TableRow from "@material-ui/core/TableRow";
import TableBody from "@material-ui/core/TableBody";
import TableCell from "@material-ui/core/TableCell";
// @material-ui/icons
import Edit from "@material-ui/icons/Edit";
import Close from "@material-ui/icons/Close";
import Check from "@material-ui/icons/Check";
// core components
import tasksStyle from "../../assets/jss/material-dashboard-react/components/tasksStyle";

interface Props {
    classes: any;
    tasksIndexes: any;
    tasks: any;
    rtlActive?: any;
    checkedIndexes: any;
}

interface State {
    checked: any;
}

class Tasks extends React.Component<Props, State> {
    constructor(props: Props) {
        super(props);
        this.state = {
            checked: this.props.checkedIndexes
        };
    }

    handleToggle = (value: any) => () => {
        const { checked } = this.state;
        const currentIndex = checked.indexOf(value);
        const newChecked = [...checked];

        if (currentIndex === -1) {
            newChecked.push(value);
        } else {
            newChecked.splice(currentIndex, 1);
        }

        this.setState({
            checked: newChecked
        });
    };

    render() {
        const { classes, tasksIndexes, tasks, rtlActive } = this.props;
        const tableCellClasses = classnames(classes.tableCell, {
            [classes.tableCellRTL]: rtlActive
        });
        return (
            <Table className={classes.table}>
                <TableBody>
                    {tasksIndexes.map((value: any) => (
                        <TableRow key={value} className={classes.tableRow}>
                            <TableCell className={tableCellClasses}>
                                <Checkbox
                                    checked={
                                        this.state.checked.indexOf(value) !== -1
                                    }
                                    tabIndex={-1}
                                    onClick={this.handleToggle(value)}
                                    checkedIcon={
                                        <Check
                                            className={classes.checkedIcon}
                                            />
                                    }
                                    icon={
                                        <Check
                                            className={classes.uncheckedIcon}
                                            />
                                    }
                                    classes={{
                                        checked: classes.checked,
                                        root: classes.root
                                    }}
                                    />
                            </TableCell>
                            <TableCell className={tableCellClasses}>
                                {tasks[value]}
                            </TableCell>
                            <TableCell className={classes.tableActions}>
                                <Tooltip
                                    id="tooltip-top"
                                    title="Edit Task"
                                    placement="top"
                                    classes={{ tooltip: classes.tooltip }}>
                                    <IconButton
                                        aria-label="Edit"
                                        className={classes.tableActionButton}>
                                        <Edit
                                            className={`${classes.tableActionButtonIcon} ${classes.edit}`}
                                            />
                                    </IconButton>
                                </Tooltip>
                                <Tooltip
                                    id="tooltip-top-start"
                                    title="Remove"
                                    placement="top"
                                    classes={{ tooltip: classes.tooltip }}>
                                    <IconButton
                                        aria-label="Close"
                                        className={classes.tableActionButton}>
                                        <Close
                                            className={`${classes.tableActionButtonIcon} ${classes.close}`}
                                            />
                                    </IconButton>
                                </Tooltip>
                            </TableCell>
                        </TableRow>
                    ))}
                </TableBody>
            </Table>
        );
    }
}

export default withStyles(tasksStyle)(Tasks);
