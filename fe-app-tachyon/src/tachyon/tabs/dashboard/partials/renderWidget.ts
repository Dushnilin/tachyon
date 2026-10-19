interface IRenderWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string;
  items: Array<{
    key: string;
    value: string;
    attributes?: {
      class?: string;
      title?: string;
    };
  }>;
}

function renderFailedState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'tachyon_dashboard-page__widgets-section__item centered',
    },
    _('Currently unavailable'),
  );
}

function renderLoadingState() {
  return E(
    'div',
    {
      id: '',
      style: 'height: 78px',
      class: 'tachyon_dashboard-page__widgets-section__item skeleton',
    },
    '',
  );
}

function renderDefaultState({ title, items }: IRenderWidgetProps) {
  return E('div', { class: 'tachyon_dashboard-page__widgets-section__item' }, [
    E(
      'b',
      { class: 'tachyon_dashboard-page__widgets-section__item__title' },
      title,
    ),
    ...items.map((item) => {
      const rowAttrs: Record<string, string> = {
        class: `tachyon_dashboard-page__widgets-section__item__row ${item?.attributes?.class || ''}`,
      };
      if (item?.attributes?.title) {
        rowAttrs.title = item.attributes.title;
      }
      return E('div', rowAttrs, [
        E(
          'span',
          {
            class: 'tachyon_dashboard-page__widgets-section__item__row__key',
          },
          `${item.key}: `,
        ),
        E(
          'span',
          {
            class: 'tachyon_dashboard-page__widgets-section__item__row__value',
            ...(item?.attributes?.title
              ? { title: item.attributes.title }
              : {}),
          },
          item.value,
        ),
      ]);
    }),
  ]);
}

export function renderWidget(props: IRenderWidgetProps) {
  if (props.loading) {
    return renderLoadingState();
  }

  if (props.failed) {
    return renderFailedState();
  }

  return renderDefaultState(props);
}
