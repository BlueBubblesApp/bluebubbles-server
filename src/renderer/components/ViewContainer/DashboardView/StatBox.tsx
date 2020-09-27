/* eslint-disable default-case */
/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import "./StatBox.css";

interface Props {
    middle?: boolean;
    title: string;
    stat: string;
}

interface State {
    bgColor: string;
}

class StatBox extends React.Component<Props, State> {
    bgColor: React.CSSProperties;

    componentDidMount() {
        this.handleTitle();
    }

    handleTitle() {
        switch (this.props.title) {
            case "All Time":
                this.bgColor = { backgroundColor: "#E23838" };
                break;
            case "Top Group":
                this.bgColor = { backgroundColor: "#F78200" };
                break;
            case "Best Friend":
                this.bgColor = { backgroundColor: "#FFB900" };
                break;
            case "Last 24 Hours":
                this.bgColor = { backgroundColor: "#5EBD3E" };
                break;
            case "Pictures":
                this.bgColor = { backgroundColor: "#147EFB" };
                break;
            case "Videos":
                this.bgColor = { backgroundColor: "#973999" };
                break;
        }
    }

    render() {
        return (
            <>
                {this.props.middle ? (
                    <div className="aStatBox middle">
                        <h3>{this.props.stat}</h3>
                        <div className="aStatBoxTitleContainer" style={this.bgColor}>
                            <h3>{this.props.title}</h3>
                        </div>
                    </div>
                ) : (
                    <div className="aStatBox">
                        <h3>{this.props.stat}</h3>
                        <div className="aStatBoxTitleContainer" style={this.bgColor}>
                            <h3>{this.props.title}</h3>
                        </div>
                    </div>
                )}
            </>
        );
    }
}

export default StatBox;
