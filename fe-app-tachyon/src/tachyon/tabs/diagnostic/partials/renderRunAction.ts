import { renderButton } from '../../../../partials';
import { renderSearchIcon24 } from '../../../../icons';

interface IRenderDiagnosticRunActionProps {
  loading: boolean;
  disabled?: boolean;
  click: () => void;
}

export function renderRunAction({
  loading,
  disabled,
  click,
}: IRenderDiagnosticRunActionProps) {
  return renderButton({
    text: _('Run Diagnostic'),
    onClick: click,
    icon: renderSearchIcon24,
    loading,
    disabled,
    classNames: ['cbi-button cbi-button-apply'],
  });
}
