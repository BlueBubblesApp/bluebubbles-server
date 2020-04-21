import * as React from 'react';

require('./Counter.scss');
const redCubeImg = require('./RedCube.jpg');

export interface Props {
    value: number;

    incrementValue: () => any;
    decrementValue: () => any;
}

const Counter: React.FunctionComponent<Props> = ({ value, incrementValue, decrementValue }) => (
    <div className="counter">
        <p>
            <img src={redCubeImg} alt="Red cube" />
        </p>
        <p id="counter-value">Current value: {value}</p>
        <p>
            <button id="increment" onClick={incrementValue}>
                Increment
            </button>
            <button id="decrement" onClick={decrementValue}>
                Decrement
            </button>
        </p>
    </div>
);

export default Counter;
