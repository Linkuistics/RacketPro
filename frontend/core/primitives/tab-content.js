// primitives/tab-content.js — hm-tab-content
//
// Container that shows only the child matching the active bottom tab.
// Children must have a `data-tab-id` attribute.

import { LitElement, html, css } from 'lit';
import { effect } from '@preact/signals-core';
import { getCell } from '../cells.js';

class HmTabContent extends LitElement {
  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      flex: 1;
      overflow: hidden;
    }

    ::slotted(*) {
      display: none !important;
    }

    ::slotted([data-tab-active]) {
      display: flex !important;
      flex-direction: column;
      flex: 1;
    }
  `;

  constructor() {
    super();
    this._disposeEffect = null;
  }

  firstUpdated() {
    setTimeout(() => {
      const tabCell = getCell('current-bottom-tab');
      this._disposeEffect = effect(() => {
        this._updateVisibility(tabCell.value);
      });
    }, 0);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    if (this._disposeEffect) this._disposeEffect();
  }

  _updateVisibility(activeTab) {
    const children = this.querySelectorAll('[data-tab-id]');
    for (const child of children) {
      if (child.getAttribute('data-tab-id') === activeTab) {
        child.setAttribute('data-tab-active', '');
      } else {
        child.removeAttribute('data-tab-active');
      }
    }
  }

  render() {
    return html`<slot></slot>`;
  }
}

customElements.define('hm-tab-content', HmTabContent);
