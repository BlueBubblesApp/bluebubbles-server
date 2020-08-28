/* eslint-disable react/prefer-stateless-function */
import * as React from "react";
import "./StatBox.css";

interface Props {
    middle?: boolean;
    title: string;
    stat: string;
}

class StatBox extends React.Component<Props,unknown> {
    constructor(props: Readonly<Props>){
        super(props);
    }
    
    render() {
        return (
            <>
            {this.props.middle ? (
                <div className="aStatBox middle">
                    <h3>{this.props.stat}</h3>
                    <div className="aStatBoxTitleContainer">
                        <h3>{this.props.title}</h3>
                    </div>
                </div>
            ) : (
                <div className="aStatBox">
                    <h3>{this.props.stat}</h3>
                    <div className="aStatBoxTitleContainer">
                        <h3>{this.props.title}</h3>
                    </div>
                </div>
            )}
            </>
        );
    }
}

export default StatBox;
