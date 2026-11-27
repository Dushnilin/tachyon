/* eslint-disable @typescript-eslint/no-explicit-any */
import { showToast } from '../../helpers/showToast';
import { renderCheckIcon } from '../../icons';
import { tr } from '../helpers/i18n';
import {
  BUILTIN_THEMES,
  BG_ANIMATION_CHANGED_EVENT,
  FONT_MONO_PRESETS,
  FONT_SANS_PRESETS,
  FONT_SIZE_PRESETS,
  FontMonoPresetId,
  FontSansPresetId,
  THEME_COLOR_FIELDS,
  TYPOGRAPHY_CHANGED_EVENT,
  TachyonThemeColors,
  TachyonThemeDefinition,
  ThemeScheme,
  applyThemeToDocument,
  deleteCustomTheme,
  exportThemeJson,
  getActiveTheme,
  getAllThemes,
  getThemeAutoConfig,
  getTypographyConfig,
  inferSchemeFromBg,
  isBgAnimationEnabled,
  normalizeHexColor,
  normalizeThemeColors,
  parseThemeImportText,
  saveCustomTheme,
  setActiveTheme,
  setBgAnimationEnabled,
  setThemeAutoConfig,
  setTypographyConfig,
  subscribeThemeChange,
} from './themeCatalog';

function createEl(
  tag: string,
  attrs: Record<string, any> = {},
  children: Array<
    HTMLElement | SVGElement | Text | string | null | undefined
  > = [],
): HTMLElement {
  const node = document.createElement(tag) as any;
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') {
      node.className = String(v);
    } else if (k === 'style') {
      node.setAttribute?.('style', String(v));
      if (typeof node.style === 'object') {
        node.style.cssText = String(v);
      }
    } else if (k === 'value') {
      node.value = String(v);
      node.setAttribute?.('value', String(v));
    } else if (k === 'checked') {
      node.checked = Boolean(v);
    } else if (k === 'disabled') {
      node.disabled = Boolean(v);
    } else if (
      ['click', 'change', 'input', 'keydown'].includes(k) &&
      typeof v === 'function'
    ) {
      node.addEventListener?.(k, v);
    } else {
      node.setAttribute?.(k, v === true ? '' : String(v));
    }
  }
  for (const child of children) {
    if (child == null) continue;
    if (typeof child === 'string') {
      node.appendChild(document.createTextNode(child));
    } else {
      node.appendChild(child);
    }
  }
  return node;
}

function downloadTextFile(filename: string, content: string): void {
  try {
    const blob = new Blob([content], {
      type: 'application/json;charset=utf-8',
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch {
    // ignore download errors in non-DOM test environments
  }
}

export function openCustomThemeModal(
  editThemeId?: string,
  initialImported?: {
    name?: string;
    scheme?: ThemeScheme;
    colors?: Partial<TachyonThemeColors>;
  },
): void {
  if (typeof document === 'undefined' || !document.body) return;

  const existingOverlay = document.getElementById(
    'tachyon-theme-modal-overlay',
  );
  existingOverlay?.remove();

  const all = getAllThemes();
  const editingCustom = editThemeId
    ? all.find((t) => t.id === editThemeId && !t.builtin)
    : undefined;
  const previousActive = getActiveTheme();

  let draftName =
    initialImported?.name ||
    editingCustom?.name ||
    tr('Моя тема', 'Custom Theme');
  let draftScheme: ThemeScheme =
    initialImported?.scheme ||
    editingCustom?.scheme ||
    previousActive.scheme ||
    'dark';
  let draftColors: TachyonThemeColors = normalizeThemeColors(
    initialImported?.colors || editingCustom?.colors || previousActive.colors,
  );
  let draftBaseId = editingCustom?.id || previousActive.id || 'default-dark';
  let showJsonPanel = Boolean(initialImported);
  let importStatusText = '';
  let importStatusErr = '';

  const applyLivePreview = () => {
    applyThemeToDocument(
      {
        id: editingCustom?.id || '__preview__',
        name: draftName,
        scheme: draftScheme,
        builtin: false,
        colors: draftColors,
      },
      false,
    );
  };

  let closed = false;
  const closeModal = (revertPreview: boolean) => {
    if (closed) return;
    closed = true;
    if (revertPreview) {
      applyThemeToDocument(previousActive, false);
    }
    overlay.remove();
    if (
      typeof window !== 'undefined' &&
      typeof window.removeEventListener === 'function'
    ) {
      window.removeEventListener('keydown', onKeyDown);
    }
  };

  const onKeyDown = (ev: KeyboardEvent) => {
    if (ev.key === 'Escape') {
      ev.preventDefault();
      closeModal(true);
    }
  };
  if (
    typeof window !== 'undefined' &&
    typeof window.addEventListener === 'function'
  ) {
    window.addEventListener('keydown', onKeyDown);
  }

  const overlay = createEl('div', {
    id: 'tachyon-theme-modal-overlay',
    class: 'tachyon-theme-modal-overlay',
    click: (ev: MouseEvent) => {
      if (ev.target === overlay) {
        closeModal(true);
      }
    },
  });

  const modal = createEl('div', {
    class: 'tachyon-theme-modal',
    role: 'dialog',
    'aria-modal': 'true',
  });

  const renderModal = () => {
    const baseSelect = createEl(
      'select',
      {
        id: 'tachyon-theme-base-select',
        class: 'tachyon-theme-input',
        change: () => {
          const picked = BUILTIN_THEMES.find((t) => t.id === baseSelect.value);
          if (picked) {
            draftBaseId = picked.id;
            draftColors = { ...picked.colors };
            draftScheme = picked.scheme;
            applyLivePreview();
            renderModal();
          }
        },
      },
      BUILTIN_THEMES.map((t) =>
        createEl(
          'option',
          {
            value: t.id,
            ...(t.id === draftBaseId ? { selected: 'selected' } : {}),
          },
          [t.name],
        ),
      ),
    ) as HTMLSelectElement;
    baseSelect.value = BUILTIN_THEMES.some((t) => t.id === draftBaseId)
      ? draftBaseId
      : 'default-dark';

    const nameInput = createEl('input', {
      id: 'tachyon-theme-name-input',
      type: 'text',
      class: 'tachyon-theme-input',
      value: draftName,
      placeholder: tr('Например: Midnight Slate', 'e.g. Midnight Slate'),
      input: () => {
        draftName = nameInput.value;
      },
    }) as HTMLInputElement;

    const schemeToggle = createEl(
      'div',
      { class: 'tachyon-theme-scheme-tabs' },
      [
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-theme-scheme-btn${draftScheme === 'dark' ? ' is-active' : ''}`,
            click: () => {
              draftScheme = 'dark';
              applyLivePreview();
              renderModal();
            },
          },
          [tr('Тёмная основа', 'Dark base')],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-theme-scheme-btn${draftScheme === 'light' ? ' is-active' : ''}`,
            click: () => {
              draftScheme = 'light';
              applyLivePreview();
              renderModal();
            },
          },
          [tr('Светлая основа', 'Light base')],
        ),
      ],
    );

    const colorGrid = createEl(
      'div',
      { class: 'tachyon-theme-pickers-grid' },
      THEME_COLOR_FIELDS.map((field) => {
        const curHex = draftColors[field.key];
        const colorInput = createEl('input', {
          type: 'color',
          value: curHex,
          class: 'tachyon-theme-color-swatch',
          'aria-label': tr(field.labelRu, field.labelEn),
        }) as HTMLInputElement;
        const hexInput = createEl('input', {
          type: 'text',
          value: curHex,
          class: 'tachyon-theme-hex-input',
          maxlength: '9',
          spellcheck: 'false',
        }) as HTMLInputElement;

        colorInput.addEventListener('input', () => {
          const norm = normalizeHexColor(colorInput.value, curHex);
          draftColors = { ...draftColors, [field.key]: norm };
          hexInput.value = norm;
          if (field.key === 'bg') {
            draftScheme = inferSchemeFromBg(norm);
          }
          applyLivePreview();
        });

        hexInput.addEventListener('input', () => {
          const norm = normalizeHexColor(hexInput.value, '');
          if (norm) {
            draftColors = { ...draftColors, [field.key]: norm };
            colorInput.value = norm;
            if (field.key === 'bg') {
              draftScheme = inferSchemeFromBg(norm);
            }
            applyLivePreview();
          }
        });

        return createEl('div', { class: 'tachyon-theme-picker-row' }, [
          createEl('div', { class: 'tachyon-theme-picker-label' }, [
            tr(field.labelRu, field.labelEn),
          ]),
          createEl('div', { class: 'tachyon-theme-picker-controls' }, [
            colorInput,
            hexInput,
          ]),
        ]);
      }),
    );

    const previewCard = createEl(
      'div',
      { class: 'tachyon-theme-live-preview' },
      [
        createEl('div', { class: 'tachyon-theme-live-preview__title' }, [
          tr('Предпросмотр палитры в реальном времени', 'Live palette preview'),
        ]),
        createEl('div', { class: 'tachyon-theme-live-preview__chips' }, [
          createEl('span', { class: 'tachyon-theme-live-chip is-accent' }, [
            tr('Акцент', 'Accent'),
          ]),
          createEl('span', { class: 'tachyon-theme-live-chip is-ok' }, [
            tr('Онлайн', 'Online'),
          ]),
          createEl('span', { class: 'tachyon-theme-live-chip is-warn' }, [
            tr('Ожидание', 'Warning'),
          ]),
          createEl('span', { class: 'tachyon-theme-live-chip is-err' }, [
            tr('Ошибка', 'Error'),
          ]),
        ]),
      ],
    );

    const jsonArea = createEl('textarea', {
      class: 'tachyon-theme-json-area',
      rows: '6',
      placeholder: tr(
        'Вставьте JSON / JSONC темы (поддерживаются поля colors, комментарии // и #hex)...',
        'Paste theme JSON / JSONC (supports colors map, // comments and #hex)...',
      ),
    }) as HTMLTextAreaElement;

    const fileInput = createEl('input', {
      type: 'file',
      accept: '.json,.jsonc,application/json',
      style: 'display:none',
      change: async () => {
        const file = fileInput.files?.[0];
        if (!file) return;
        try {
          const text = await file.text();
          jsonArea.value = text;
          const parsed = parseThemeImportText(text);
          draftName = parsed.name || draftName;
          draftScheme = parsed.scheme;
          draftColors = parsed.colors;
          importStatusErr = '';
          importStatusText = tr(
            `Импортировано из ${file.name}`,
            `Imported from ${file.name}`,
          );
          applyLivePreview();
          renderModal();
        } catch (err: any) {
          importStatusText = '';
          importStatusErr =
            err?.message ||
            tr('Некорректный JSON/JSONC темы', 'Invalid theme JSON/JSONC');
          renderModal();
        }
      },
    }) as HTMLInputElement;

    const jsonToolsBlock = showJsonPanel
      ? createEl('div', { class: 'tachyon-theme-json-panel' }, [
          jsonArea,
          ...(importStatusErr
            ? [
                createEl('div', { class: 'tachyon-theme-json-err' }, [
                  importStatusErr,
                ]),
              ]
            : importStatusText
              ? [
                  createEl('div', { class: 'tachyon-theme-json-ok' }, [
                    importStatusText,
                  ]),
                ]
              : []),
          createEl('div', { class: 'tachyon-theme-json-actions' }, [
            fileInput,
            createEl(
              'button',
              {
                type: 'button',
                class: 'btn',
                click: () => fileInput.click(),
              },
              [tr('Загрузить файл .json', 'Load .json file')],
            ),
            createEl(
              'button',
              {
                type: 'button',
                class: 'btn',
                click: () => {
                  try {
                    const parsed = parseThemeImportText(jsonArea.value);
                    draftName = parsed.name || draftName;
                    draftScheme = parsed.scheme;
                    draftColors = parsed.colors;
                    importStatusErr = '';
                    importStatusText = tr(
                      'Палитра применена к редактору.',
                      'Palette applied to editor.',
                    );
                    applyLivePreview();
                    renderModal();
                  } catch (err: any) {
                    importStatusText = '';
                    importStatusErr =
                      err?.message ||
                      tr(
                        'Ошибка разбора JSON/JSONC',
                        'Failed to parse JSON/JSONC',
                      );
                    renderModal();
                  }
                },
              },
              [tr('Применить JSON', 'Apply JSON')],
            ),
            createEl(
              'button',
              {
                type: 'button',
                class: 'btn',
                click: async () => {
                  const json = exportThemeJson({
                    id: editingCustom?.id || 'custom-theme',
                    name: draftName || 'Custom Theme',
                    scheme: draftScheme,
                    colors: draftColors,
                  });
                  try {
                    await navigator.clipboard?.writeText(json);
                    showToast(
                      tr('JSON темы скопирован', 'Theme JSON copied'),
                      'success',
                    );
                  } catch {
                    jsonArea.value = json;
                  }
                },
              },
              [tr('Копировать JSON', 'Copy JSON')],
            ),
            createEl(
              'button',
              {
                type: 'button',
                class: 'btn',
                click: () => {
                  const safeName = (draftName || 'custom-theme')
                    .trim()
                    .toLowerCase()
                    .replace(/[^a-z0-9-_]+/g, '-');
                  const json = exportThemeJson({
                    id: editingCustom?.id || safeName || 'custom-theme',
                    name: draftName || 'Custom Theme',
                    scheme: draftScheme,
                    colors: draftColors,
                  });
                  downloadTextFile(`${safeName || 'custom-theme'}.json`, json);
                },
              },
              [tr('Скачать .json', 'Download .json')],
            ),
          ]),
        ])
      : null;

    modal.replaceChildren(
      createEl('div', { class: 'tachyon-theme-modal__hdr' }, [
        createEl('div', { class: 'tachyon-theme-modal__title' }, [
          editingCustom
            ? tr('Редактирование темы', 'Edit Custom Theme')
            : tr('Конструктор своей темы', 'Custom Theme Builder'),
        ]),
        createEl(
          'button',
          {
            type: 'button',
            class: 'btn tachyon-theme-modal__close',
            'aria-label': tr('Закрыть', 'Close'),
            click: () => closeModal(true),
          },
          ['×'],
        ),
      ]),
      createEl('div', { class: 'tachyon-theme-modal__body' }, [
        createEl('div', { class: 'tachyon-theme-meta-row' }, [
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl('label', { class: 'tachyon-theme-meta-lbl' }, [
              tr('Название темы', 'Theme name'),
            ]),
            nameInput,
          ]),
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl('label', { class: 'tachyon-theme-meta-lbl' }, [
              tr('Взять за основу', 'Base preset'),
            ]),
            baseSelect,
          ]),
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl('label', { class: 'tachyon-theme-meta-lbl' }, [
              tr('Схема контраста', 'Contrast scheme'),
            ]),
            schemeToggle,
          ]),
        ]),
        previewCard,
        colorGrid,
        createEl('div', { class: 'tachyon-theme-json-toggle-row' }, [
          createEl(
            'button',
            {
              type: 'button',
              class: 'btn',
              click: () => {
                showJsonPanel = !showJsonPanel;
                renderModal();
              },
            },
            [
              showJsonPanel
                ? tr(
                    'Скрыть импорт / экспорт JSON',
                    'Hide JSON Import / Export',
                  )
                : tr(
                    'Импорт / экспорт JSON / JSONC',
                    'Import / Export JSON / JSONC',
                  ),
            ],
          ),
        ]),
        jsonToolsBlock,
      ]),
      createEl('div', { class: 'tachyon-theme-modal__ftr' }, [
        createEl(
          'button',
          {
            type: 'button',
            class: 'btn',
            click: () => closeModal(true),
          },
          [tr('Отмена', 'Cancel')],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button-apply',
            click: () => {
              const finalName =
                draftName.trim() || tr('Моя тема', 'Custom Theme');
              const saved = saveCustomTheme({
                id: editingCustom?.id,
                name: finalName,
                scheme: draftScheme,
                colors: draftColors,
              });
              setActiveTheme(saved.id);
              showToast(
                `${tr('Тема сохранена:', 'Theme saved:')} ${saved.name}`,
                'success',
              );
              closeModal(false);
            },
          },
          [tr('Сохранить и применить', 'Save & Apply')],
        ),
      ]),
    );
  };

  renderModal();
  applyLivePreview();
  overlay.appendChild(modal);
  document.body.appendChild(overlay);
}

export function createTopbarThemeDropdown(): HTMLElement {
  const wrap = createEl('div', { class: 'tachyon-theme-dropdown-wrap' });
  let isOpen = false;

  const render = () => {
    const active = getActiveTheme();
    const autoCfg = getThemeAutoConfig();
    const themes = getAllThemes();
    const modeLabel =
      autoCfg.mode === 'system'
        ? tr('Как в браузере', 'Browser')
        : autoCfg.mode === 'schedule'
          ? `${tr('По расписанию', 'Schedule')} ${autoCfg.scheduleStart}–${autoCfg.scheduleEnd}`
          : '';
    const btn = createEl(
      'button',
      {
        type: 'button',
        class: `tachyon-topbar__icon-btn tachyon-theme-trigger${isOpen ? ' is-open' : ''}`,
        title: modeLabel
          ? `${tr('Тема интерфейса', 'Interface Theme')}: ${active.name} (${modeLabel})`
          : `${tr('Тема интерфейса', 'Interface Theme')}: ${active.name}`,
        'aria-expanded': isOpen ? 'true' : 'false',
        click: (ev: MouseEvent) => {
          ev.preventDefault();
          ev.stopPropagation();
          isOpen = !isOpen;
          render();
        },
      },
      [
        createEl('span', {
          class: 'tachyon-theme-trigger__dot',
          style: `background:${active.colors.accent}`,
        }),
        createEl('span', { class: 'tachyon-theme-trigger__name' }, [
          active.name,
        ]),
      ],
    );

    const children: HTMLElement[] = [btn];
    if (isOpen) {
      const autoModeItems: HTMLElement[] = [
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-theme-menu__item${autoCfg.mode === 'system' ? ' is-active' : ''}`,
            'data-theme-auto-mode': 'system',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              setThemeAutoConfig({ mode: 'system' });
              isOpen = false;
              render();
            },
          },
          [
            createEl('span', { class: 'tachyon-theme-menu__label' }, [
              tr('Как в браузере', 'Follow browser'),
            ]),
            autoCfg.mode === 'system'
              ? createEl('span', { class: 'tachyon-theme-menu__check' }, [
                  renderCheckIcon(13),
                ])
              : null,
          ],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-theme-menu__item${autoCfg.mode === 'schedule' ? ' is-active' : ''}`,
            'data-theme-auto-mode': 'schedule',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              setThemeAutoConfig({ mode: 'schedule' });
              isOpen = false;
              render();
            },
          },
          [
            createEl('span', { class: 'tachyon-theme-menu__label' }, [
              `${tr('По расписанию', 'Schedule')} (${autoCfg.scheduleStart}–${autoCfg.scheduleEnd})`,
            ]),
            autoCfg.mode === 'schedule'
              ? createEl('span', { class: 'tachyon-theme-menu__check' }, [
                  renderCheckIcon(13),
                ])
              : null,
          ],
        ),
        createEl('div', { class: 'tachyon-theme-menu__sep' }),
      ];

      const menuItems = [
        ...autoModeItems,
        ...themes.map((t) => {
          const isCurrent = t.id === active.id;
          return createEl(
            'button',
            {
              type: 'button',
              class: `tachyon-theme-menu__item${isCurrent ? ' is-active' : ''}`,
              'data-theme-id': t.id,
              click: (ev: MouseEvent) => {
                ev.preventDefault();
                ev.stopPropagation();
                setActiveTheme(t.id);
                isOpen = false;
                render();
              },
            },
            [
              createEl('span', { class: 'tachyon-theme-menu__swatch-pair' }, [
                createEl('span', {
                  class: 'tachyon-theme-menu__swatch-bg',
                  style: `background:${t.colors.bg}`,
                }),
                createEl('span', {
                  class: 'tachyon-theme-menu__swatch-accent',
                  style: `background:${t.colors.accent}`,
                }),
              ]),
              createEl('span', { class: 'tachyon-theme-menu__label' }, [
                t.name,
              ]),
              isCurrent
                ? createEl('span', { class: 'tachyon-theme-menu__check' }, [
                    renderCheckIcon(13),
                  ])
                : null,
            ],
          );
        }),
      ];

      const animEnabled = isBgAnimationEnabled();
      menuItems.push(
        createEl('div', { class: 'tachyon-theme-menu__sep' }),
        createEl(
          'button',
          {
            type: 'button',
            class: `tachyon-theme-menu__item${animEnabled ? ' is-active' : ''}`,
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              setBgAnimationEnabled(!animEnabled);
              render();
            },
          },
          [
            createEl('span', { class: 'tachyon-theme-menu__label' }, [
              animEnabled
                ? tr('✓ Анимация фона: Вкл', '✓ Background animation: On')
                : tr('○ Анимация фона: Выкл', '○ Background animation: Off'),
            ]),
          ],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: 'tachyon-theme-menu__item tachyon-theme-menu__item--create',
            click: (ev: MouseEvent) => {
              ev.preventDefault();
              ev.stopPropagation();
              isOpen = false;
              render();
              openCustomThemeModal();
            },
          },
          [tr('+ Создать свою тему...', '+ Create custom theme...')],
        ),
      );

      children.push(
        createEl('div', { class: 'tachyon-theme-menu' }, menuItems),
      );
    }

    wrap.replaceChildren(...children);
  };

  if (
    typeof document !== 'undefined' &&
    typeof document.addEventListener === 'function'
  ) {
    const g = document as any;
    if (
      g.__tachyonThemeDocClickHandler &&
      typeof document.removeEventListener === 'function'
    ) {
      document.removeEventListener('click', g.__tachyonThemeDocClickHandler);
    }
    g.__tachyonThemeDocClickHandler = (ev: MouseEvent) => {
      if (!isOpen) return;
      const target = ev.target as Node | null;
      if (target && wrap.contains?.(target)) return;
      isOpen = false;
      render();
    };
    document.addEventListener('click', g.__tachyonThemeDocClickHandler);
  }

  subscribeThemeChange(() => {
    render();
  });

  if (
    typeof window !== 'undefined' &&
    typeof window.addEventListener === 'function'
  ) {
    window.addEventListener(BG_ANIMATION_CHANGED_EVENT, () => {
      render();
    });
  }

  render();
  return wrap;
}

export function renderThemeSettingsCard(): HTMLElement {
  const card = createEl('div', { class: 'tachyon-theme-settings-card' });

  const render = () => {
    const active = getActiveTheme();
    const autoCfg = getThemeAutoConfig();
    const themes = getAllThemes();

    const importFileInput = createEl('input', {
      type: 'file',
      accept: '.json,.jsonc,application/json',
      style: 'display:none',
      change: async () => {
        const file = importFileInput.files?.[0];
        if (!file) return;
        try {
          const text = await file.text();
          const parsed = parseThemeImportText(text);
          openCustomThemeModal(undefined, parsed);
        } catch (err: any) {
          showToast(
            err?.message ||
              tr(
                'Не удалось импортировать файл темы',
                'Failed to import theme file',
              ),
            'error',
          );
        }
      },
    }) as HTMLInputElement;

    const subText =
      autoCfg.mode === 'system'
        ? `${tr('Режим: как в браузере', 'Mode: follow browser')} · ${tr('Активная тема:', 'Active theme:')} ${active.name}`
        : autoCfg.mode === 'schedule'
          ? `${tr('Режим: по расписанию', 'Mode: schedule')} (${autoCfg.scheduleStart}–${autoCfg.scheduleEnd}) · ${tr('Активная тема:', 'Active theme:')} ${active.name}`
          : `${tr('Активная тема:', 'Active theme:')} ${active.name}`;

    const header = createEl('div', { class: 'tachyon-theme-settings-hdr' }, [
      createEl('div', {}, [
        createEl('div', { class: 'tachyon-theme-settings-title' }, [
          tr('Цветовая тема интерфейса', 'Interface Color Theme'),
        ]),
        createEl('div', { class: 'tachyon-theme-settings-sub' }, [subText]),
      ]),
      createEl('div', { class: 'tachyon-theme-settings-actions' }, [
        importFileInput,
        createEl(
          'button',
          {
            type: 'button',
            class: `btn${isBgAnimationEnabled() ? ' cbi-button-action' : ''}`,
            click: () => {
              setBgAnimationEnabled(!isBgAnimationEnabled());
              render();
            },
          },
          [
            isBgAnimationEnabled()
              ? tr('Анимация фона: Вкл', 'Background animation: On')
              : tr('Анимация фона: Выкл', 'Background animation: Off'),
          ],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: 'btn',
            click: () => importFileInput.click(),
          },
          [tr('Импорт JSON', 'Import JSON')],
        ),
        createEl(
          'button',
          {
            type: 'button',
            class: 'btn cbi-button-apply',
            click: () => openCustomThemeModal(),
          },
          [tr('+ Своя тема', '+ Custom Theme')],
        ),
      ]),
    ]);

    const makeThemeSelect = (
      id: string,
      selectedId: string,
      onChange: (nextId: string) => void,
    ) => {
      const sel = createEl(
        'select',
        {
          id,
          class: 'tachyon-theme-input',
          change: () => onChange(sel.value),
        },
        themes.map((t) =>
          createEl(
            'option',
            {
              value: t.id,
              ...(t.id === selectedId ? { selected: 'selected' } : {}),
            },
            [
              `${t.name} (${t.scheme === 'light' ? tr('Светлая', 'Light') : tr('Тёмная', 'Dark')})`,
            ],
          ),
        ),
      ) as HTMLSelectElement;
      sel.value = selectedId;
      return sel;
    };

    const makeTimeInput = (
      id: string,
      value: string,
      onChange: (val: string) => void,
    ) =>
      createEl('input', {
        id,
        type: 'time',
        class: 'tachyon-theme-input tachyon-theme-time-input',
        value,
        change: (ev: Event) => {
          const input = ev.currentTarget as HTMLInputElement;
          onChange(input.value);
        },
      }) as HTMLInputElement;

    const autoControlsChildren: HTMLElement[] = [
      createEl('div', { class: 'tachyon-theme-auto-modes' }, [
        createEl('div', { class: 'tachyon-theme-meta-lbl' }, [
          tr('Режим переключения', 'Switching mode'),
        ]),
        createEl('div', { class: 'tachyon-theme-scheme-tabs' }, [
          createEl(
            'button',
            {
              type: 'button',
              class: `tachyon-theme-scheme-btn${autoCfg.mode === 'manual' ? ' is-active' : ''}`,
              'data-theme-mode-btn': 'manual',
              click: () => {
                setThemeAutoConfig({ mode: 'manual' });
              },
            },
            [tr('Вручную', 'Manual')],
          ),
          createEl(
            'button',
            {
              type: 'button',
              class: `tachyon-theme-scheme-btn${autoCfg.mode === 'system' ? ' is-active' : ''}`,
              'data-theme-mode-btn': 'system',
              click: () => {
                setThemeAutoConfig({ mode: 'system' });
              },
            },
            [tr('Как в браузере', 'Browser')],
          ),
          createEl(
            'button',
            {
              type: 'button',
              class: `tachyon-theme-scheme-btn${autoCfg.mode === 'schedule' ? ' is-active' : ''}`,
              'data-theme-mode-btn': 'schedule',
              click: () => {
                setThemeAutoConfig({ mode: 'schedule' });
              },
            },
            [tr('По расписанию', 'Schedule')],
          ),
        ]),
      ]),
    ];

    if (autoCfg.mode === 'system' || autoCfg.mode === 'schedule') {
      autoControlsChildren.push(
        createEl('div', { class: 'tachyon-theme-auto-pair' }, [
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl(
              'label',
              {
                class: 'tachyon-theme-meta-lbl',
                for: 'tachyon-theme-day-select',
              },
              [tr('Светлая (дневная) тема', 'Light (day) theme')],
            ),
            makeThemeSelect(
              'tachyon-theme-day-select',
              autoCfg.lightThemeId,
              (lightThemeId) => setThemeAutoConfig({ lightThemeId }),
            ),
          ]),
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl(
              'label',
              {
                class: 'tachyon-theme-meta-lbl',
                for: 'tachyon-theme-night-select',
              },
              [tr('Тёмная (ночная) тема', 'Dark (night) theme')],
            ),
            makeThemeSelect(
              'tachyon-theme-night-select',
              autoCfg.darkThemeId,
              (darkThemeId) => setThemeAutoConfig({ darkThemeId }),
            ),
          ]),
        ]),
      );
    }

    if (autoCfg.mode === 'schedule') {
      autoControlsChildren.push(
        createEl('div', { class: 'tachyon-theme-auto-schedule' }, [
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl(
              'label',
              {
                class: 'tachyon-theme-meta-lbl',
                for: 'tachyon-theme-schedule-start',
              },
              [tr('Начало ночной темы', 'Night theme start')],
            ),
            makeTimeInput(
              'tachyon-theme-schedule-start',
              autoCfg.scheduleStart,
              (scheduleStart) => setThemeAutoConfig({ scheduleStart }),
            ),
          ]),
          createEl('div', { class: 'tachyon-theme-meta-col' }, [
            createEl(
              'label',
              {
                class: 'tachyon-theme-meta-lbl',
                for: 'tachyon-theme-schedule-end',
              },
              [tr('Начало дневной темы', 'Day theme start')],
            ),
            makeTimeInput(
              'tachyon-theme-schedule-end',
              autoCfg.scheduleEnd,
              (scheduleEnd) => setThemeAutoConfig({ scheduleEnd }),
            ),
          ]),
        ]),
      );
    }

    const autoBar = createEl(
      'div',
      { class: 'tachyon-theme-auto-bar' },
      autoControlsChildren,
    );

    const typoCfg = getTypographyConfig();
    const makeFontSelect = <T extends string>(
      id: string,
      presets: ReadonlyArray<{ id: T; labelRu: string; labelEn: string }>,
      selectedId: T,
      onChange: (nextId: T) => void,
    ) => {
      const sel = createEl(
        'select',
        {
          id,
          class: 'tachyon-theme-input',
          change: () => onChange(sel.value as T),
        },
        presets.map((p) =>
          createEl(
            'option',
            {
              value: p.id,
              ...(p.id === selectedId ? { selected: 'selected' } : {}),
            },
            [tr(p.labelRu, p.labelEn)],
          ),
        ),
      ) as HTMLSelectElement;
      sel.value = selectedId;
      return sel;
    };

    const typographyBar = createEl('div', { class: 'tachyon-theme-auto-bar' }, [
      createEl('div', { class: 'tachyon-theme-auto-pair' }, [
        createEl('div', { class: 'tachyon-theme-meta-col' }, [
          createEl(
            'label',
            {
              class: 'tachyon-theme-meta-lbl',
              for: 'tachyon-font-sans-select',
            },
            [tr('Шрифт интерфейса', 'Interface font')],
          ),
          makeFontSelect<FontSansPresetId>(
            'tachyon-font-sans-select',
            FONT_SANS_PRESETS,
            typoCfg.sans,
            (sans) => setTypographyConfig({ sans }),
          ),
        ]),
        createEl('div', { class: 'tachyon-theme-meta-col' }, [
          createEl(
            'label',
            {
              class: 'tachyon-theme-meta-lbl',
              for: 'tachyon-font-mono-select',
            },
            [tr('Моноширинный шрифт', 'Monospace font')],
          ),
          makeFontSelect<FontMonoPresetId>(
            'tachyon-font-mono-select',
            FONT_MONO_PRESETS,
            typoCfg.mono,
            (mono) => setTypographyConfig({ mono }),
          ),
        ]),
      ]),
      createEl('div', { class: 'tachyon-theme-auto-modes' }, [
        createEl('div', { class: 'tachyon-theme-meta-lbl' }, [
          tr('Размер текста', 'Font size'),
        ]),
        createEl(
          'div',
          { class: 'tachyon-theme-scheme-tabs' },
          FONT_SIZE_PRESETS.map((sz) =>
            createEl(
              'button',
              {
                type: 'button',
                class: `tachyon-theme-scheme-btn${typoCfg.size === sz.id ? ' is-active' : ''}`,
                'data-font-size-btn': sz.id,
                click: () => setTypographyConfig({ size: sz.id }),
              },
              [tr(sz.labelRu, sz.labelEn)],
            ),
          ),
        ),
      ]),
    ]);

    const grid = createEl(
      'div',
      { class: 'tachyon-theme-cards-grid' },
      themes.map((t: TachyonThemeDefinition) => {
        const isCurrent = t.id === active.id;
        const isAutoDay =
          autoCfg.mode !== 'manual' && t.id === autoCfg.lightThemeId;
        const isAutoNight =
          autoCfg.mode !== 'manual' && t.id === autoCfg.darkThemeId;
        const roleTags: string[] = [];
        if (isAutoDay) roleTags.push(tr('День', 'Day'));
        if (isAutoNight) roleTags.push(tr('Ночь', 'Night'));
        if (isCurrent) roleTags.push(tr('Активна', 'Active'));
        const statusText = roleTags.join(' · ');

        return createEl(
          'div',
          {
            class: `tachyon-theme-card${isCurrent ? ' is-active' : ''}`,
            'data-theme-card-id': t.id,
            click: () => setActiveTheme(t.id),
          },
          [
            createEl(
              'div',
              {
                class: 'tachyon-theme-card__preview',
                style: `background:${t.colors.bg};border-color:${t.colors.elevated}`,
              },
              [
                createEl(
                  'div',
                  {
                    class: 'tachyon-theme-card__preview-bar',
                    style: `background:${t.colors.surface}`,
                  },
                  [
                    createEl('span', {
                      class: 'tachyon-theme-card__dot',
                      style: `background:${t.colors.accent}`,
                    }),
                    createEl('span', {
                      class: 'tachyon-theme-card__dot',
                      style: `background:${t.colors.success}`,
                    }),
                    createEl('span', {
                      class: 'tachyon-theme-card__dot',
                      style: `background:${t.colors.warn}`,
                    }),
                    createEl('span', {
                      class: 'tachyon-theme-card__dot',
                      style: `background:${t.colors.danger}`,
                    }),
                  ],
                ),
                createEl(
                  'div',
                  { class: 'tachyon-theme-card__preview-lines' },
                  [
                    createEl('span', {
                      class: 'tachyon-theme-card__line',
                      style: `background:${t.colors.text};width:65%`,
                    }),
                    createEl('span', {
                      class: 'tachyon-theme-card__line',
                      style: `background:${t.colors.text2};width:42%`,
                    }),
                  ],
                ),
              ],
            ),
            createEl('div', { class: 'tachyon-theme-card__footer' }, [
              createEl('div', { class: 'tachyon-theme-card__name-wrap' }, [
                createEl('span', { class: 'tachyon-theme-card__name' }, [
                  t.name,
                ]),
                createEl('span', { class: 'tachyon-theme-card__scheme' }, [
                  t.scheme === 'light'
                    ? tr('Светлая', 'Light')
                    : tr('Тёмная', 'Dark'),
                ]),
              ]),
              !t.builtin
                ? createEl('div', { class: 'tachyon-theme-card__custom-ops' }, [
                    createEl(
                      'button',
                      {
                        type: 'button',
                        class: 'btn tachyon-theme-mini-btn',
                        title: tr('Редактировать тему', 'Edit theme'),
                        click: (ev: MouseEvent) => {
                          ev.stopPropagation();
                          openCustomThemeModal(t.id);
                        },
                      },
                      [tr('Изм.', 'Edit')],
                    ),
                    createEl(
                      'button',
                      {
                        type: 'button',
                        class: 'btn tachyon-theme-mini-btn',
                        title: tr('Удалить тему', 'Delete theme'),
                        click: (ev: MouseEvent) => {
                          ev.stopPropagation();
                          deleteCustomTheme(t.id);
                        },
                      },
                      ['×'],
                    ),
                  ])
                : statusText
                  ? createEl(
                      'span',
                      { class: 'tachyon-theme-card__active-tag' },
                      [statusText],
                    )
                  : null,
            ]),
          ],
        );
      }),
    );

    card.replaceChildren(header, autoBar, typographyBar, grid);
  };

  subscribeThemeChange(() => {
    render();
  });

  if (
    typeof window !== 'undefined' &&
    typeof window.addEventListener === 'function'
  ) {
    window.addEventListener(BG_ANIMATION_CHANGED_EVENT, () => {
      render();
    });
    window.addEventListener(TYPOGRAPHY_CHANGED_EVENT, () => {
      render();
    });
  }

  render();
  return card;
}
