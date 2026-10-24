interface IRenderWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string;
  items: Array<{
    key?: string | HTMLElement;
    value: string | HTMLElement | (string | HTMLElement)[];
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
          typeof item.key === 'string'
            ? item.key
              ? `${item.key}: `
              : ''
            : item.key || '',
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

export interface IRenderDualWidgetColumn {
  title?: string;
  items: Array<{
    key?: string | HTMLElement;
    value: string | HTMLElement | (string | HTMLElement)[];
    attributes?: {
      class?: string;
      title?: string;
      [key: string]: string | undefined;
    };
  }>;
}

export interface IRenderDualWidgetProps {
  loading: boolean;
  failed: boolean;
  title: string | HTMLElement;
  badge?: string | HTMLElement;
  columns: [IRenderDualWidgetColumn, IRenderDualWidgetColumn];
  attributes?: Record<string, string>;
}

export function renderDualWidget(props: IRenderDualWidgetProps) {
  if (props.loading) {
    return renderLoadingState();
  }

  if (props.failed) {
    return renderFailedState();
  }

  const headerChildren: (string | HTMLElement)[] = [
    typeof props.title === 'string'
      ? E('span', { class: 'tachyon-dual-card__title-text' }, props.title)
      : props.title,
  ];

  if (props.badge) {
    headerChildren.push(
      typeof props.badge === 'string'
        ? E('span', { class: 'tachyon-dual-card__badge' }, props.badge)
        : props.badge,
    );
  }

  return E(
    'div',
    {
      ...props.attributes,
      class: `tachyon_dashboard-page__widgets-section__item tachyon-dual-card ${props.attributes?.class || ''}`,
    },
    [
      E('div', { class: 'tachyon-dual-card__header' }, headerChildren),
      E(
        'div',
        { class: 'tachyon-dual-card__body' },
        props.columns.map((col) =>
          E('div', { class: 'tachyon-dual-card__col' }, [
            col.title
              ? E(
                  'div',
                  { class: 'tachyon-dual-card__column-title' },
                  col.title,
                )
              : '',
            ...col.items.map((item) => {
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
                    class:
                      'tachyon_dashboard-page__widgets-section__item__row__key',
                  },
                  typeof item.key === 'string'
                    ? item.key
                      ? `${item.key}: `
                      : ''
                    : item.key || '',
                ),
                E(
                  'span',
                  {
                    class:
                      'tachyon_dashboard-page__widgets-section__item__row__value',
                    ...(item?.attributes?.title
                      ? { title: item.attributes.title }
                      : {}),
                  },
                  item.value,
                ),
              ]);
            }),
          ]),
        ),
      ),
    ],
  );
}
