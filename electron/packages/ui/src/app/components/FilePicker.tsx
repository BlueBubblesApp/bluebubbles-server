import { Input, InputGroup, InputGroupProps } from '@chakra-ui/input';
import { Button, ButtonProps, InputRightAddon } from '@chakra-ui/react';
import React from 'react';
import PropTypes from 'prop-types';

interface FilePickerProps {
    onFileChange: (fileList: Array<File>) => void;
    onClear: () => void;
    placeholder: string;
    clearButtonLabel?: string;
    hideClearButton?: boolean;
    multipleFiles?: boolean;
    accept?: string;
    inputProps?: InputGroupProps;
    inputGroupProps?: InputGroupProps;
    buttonProps?: ButtonProps;
}

interface FilePickerState {
    files: File[];
}

class FilePicker extends React.Component<FilePickerProps, FilePickerState> {
    static defaultProps = {
        clearButtonLabel: 'Clear',
        multipleFiles: false,
        accept: undefined,
        hideClearButton: false,
        inputProps: undefined,
        inputGroupProps: undefined,
        buttonProps: undefined
    };

    private inputRef = React.createRef<HTMLInputElement>();

    constructor(props: FilePickerProps) {
        super(props);

        this.state = {
            files: [],
        };
    }

    public reset = (): void => this.handleOnClearClick();

    private handleOnFileChange = (ev: React.ChangeEvent<HTMLInputElement>) => {
        const files = [];
        for (const f of ev.target?.files ?? []) {
            files.push(f);
        }

        this.setState({ files });
        this.clearInnerInput();
        if (this.props.onFileChange) {
            this.props.onFileChange(files);
        }
    };

    private handleOnClearClick = () => {
        this.setState({ files: [] });
        this.clearInnerInput();
        if (this.props.onClear) {
            this.props.onClear();
        }
    };

    private clearInnerInput() {
        if (this.inputRef?.current) {
            this.inputRef.current.value = '';
        }
    }

    private handleOnInputClick = () => {
        if (this.inputRef?.current) {
            this.inputRef.current.value = '';

            this.inputRef.current.click();
        }
    };

    render = (): JSX.Element => {
        const {
            placeholder,
            clearButtonLabel,
            hideClearButton,
            multipleFiles,
            accept,
            inputProps,
            inputGroupProps
        } = this.props;

        return (
            <InputGroup {...inputGroupProps}>
                <input
                    type="file"
                    ref={this.inputRef}
                    accept={accept}
                    style={{ display: 'none' }}
                    multiple={multipleFiles}
                    onChange={this.handleOnFileChange}
                    data-testid={placeholder}
                />

                <Input
                    placeholder={placeholder}
                    {...{
                        ...inputProps,
                        readOnly: true,
                        isReadOnly: true,
                        value: this.state.files.map(f => f.name).join(', '),
                        onClick: this.handleOnInputClick
                    }}
                />

                {!hideClearButton && (
                    <ClearButton
                        clearButtonLabel={clearButtonLabel ?? 'Clear'}
                        onButtonClick={this.handleOnClearClick}
                    />
                )}
            </InputGroup>
        );
    };
}

type ClearButtonProps = Pick<FilePickerProps, 'clearButtonLabel' | 'buttonProps'> & {
    onButtonClick: () => void;
};

const ClearButton: React.FC<ClearButtonProps> = ({
    clearButtonLabel,
    onButtonClick,
    buttonProps
}) => (
    <InputRightAddon background={'transparent'} borderColor={'transparent'}>
        <Button {...buttonProps} onClick={onButtonClick}>
            {clearButtonLabel ?? 'Clear'}
        </Button>
    </InputRightAddon>
);

ClearButton.propTypes = {
    clearButtonLabel: PropTypes.string,
    onButtonClick: PropTypes.func.isRequired,
    buttonProps: PropTypes.object
};

export default FilePicker;
