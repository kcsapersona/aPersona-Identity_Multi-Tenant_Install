/**
 * Predefined SAML Relying Party Templates
 *
 * These templates provide pre-configured settings for popular SAML Service Providers.
 * When an admin selects a template, the form auto-fills with known-good defaults.
 *
 * Template structure:
 *   - display_name: Human-readable name
 *   - login_url: SP login page URL
 *   - logo_url: SP logo image URL
 *   - sp.metadata_url: SP SAML metadata URL
 *   - claim_mappings: OIDC↔SAML attribute mappings
 *   - saml.nameid: NameID format and source claim
 *   - editable_fields: Fields the admin can modify
 *   - locked_fields: Fields that should not be changed (read-only in UI)
 *
 * Note on Cognito custom attributes in claim_mappings:
 *   samlgw2 uses ";" instead of ":" for custom attribute prefix.
 *   e.g., "custom:immutableId" → "custom;immutableId"
 *   The gateway handles the translation internally.
 */

export const RP_TEMPLATES = {
  microsoft: {
    id: "microsoft",
    display_name: "Microsoft Entra ID (Azure AD)",
    login_url: "https://login.microsoftonline.com/",
    logo_url: "https://learn.microsoft.com/media/logos/logo-ms-social.png",
    sp: {
      metadata_url:
        "https://nexus.microsoftonline-p.com/federationmetadata/saml20/federationmetadata.xml",
    },
    claim_mappings: {
      saml_to_oidc: {
        UserPrincipalName: ["email"],
      },
      oidc_to_saml: {
        // Microsoft federated sign-in requires IDPEmail = UserPrincipalName;
        // the ImmutableID travels in the NameID (saml.nameid.source_claim below)
        email: ["UserPrincipalName", "IDPEmail"],
      },
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
        // Must be the Entra OnPremisesImmutableId, i.e. base64(objectGUID),
        // which AD Sync writes to the Cognito attribute custom:immutableId
        source_claim: "custom:immutableId",
      },
    },
    editable_fields: [
      "login_url",
      "logo_url",
      "claim_mappings",
      "saml.nameid.source_claim",
    ],
    locked_fields: ["sp.metadata_url"],
  },

  dropbox: {
    id: "dropbox",
    display_name: "Dropbox Business",
    login_url: "https://www.dropbox.com/login",
    logo_url:
      "https://cfl.dropboxstatic.com/static/images/logo_catalog/dropbox_logo_glyph_m1.svg",
    sp: {
      metadata_url:
        "https://www.dropbox.com/static/images/business/sso-metadata.xml",
    },
    claim_mappings: {
      saml_to_oidc: {
        UserPrincipalName: ["email"],
      },
      oidc_to_saml: {
        email: ["UserPrincipalName"],
        locale: ["NameID"],
      },
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
        source_claim: "email",
      },
    },
    editable_fields: ["login_url", "logo_url", "claim_mappings"],
    locked_fields: ["sp.metadata_url"],
  },

  google_workspace: {
    id: "google_workspace",
    display_name: "Google Workspace",
    login_url: "https://accounts.google.com/",
    logo_url:
      "https://www.gstatic.com/images/branding/product/2x/hh_google_icons_workspace_96dp.png",
    sp: {
      metadata_url: "", // Customer must provide their own Google metadata URL
    },
    claim_mappings: {
      saml_to_oidc: {
        UserPrincipalName: ["email"],
      },
      oidc_to_saml: {
        email: ["UserPrincipalName"],
      },
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
        source_claim: "email",
      },
    },
    editable_fields: [
      "login_url",
      "logo_url",
      "sp.metadata_url",
      "claim_mappings",
    ],
    locked_fields: [],
  },

  salesforce: {
    id: "salesforce",
    display_name: "Salesforce",
    login_url: "https://login.salesforce.com/",
    logo_url:
      "https://www.salesforce.com/content/dam/sfdc-docs/www/logos/logo-salesforce.svg",
    sp: {
      metadata_url: "", // Customer must provide their Salesforce metadata URL
    },
    claim_mappings: {
      saml_to_oidc: {
        UserPrincipalName: ["email"],
      },
      oidc_to_saml: {
        email: ["UserPrincipalName"],
      },
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
        source_claim: "email",
      },
    },
    editable_fields: [
      "login_url",
      "logo_url",
      "sp.metadata_url",
      "claim_mappings",
    ],
    locked_fields: [],
  },

  servicenow: {
    id: "servicenow",
    display_name: "ServiceNow",
    login_url: "", // Customer-specific instance URL
    logo_url:
      "https://www.servicenow.com/content/dam/servicenow-assets/public/en-us/images/ds-backgrounds/background-now-platform.jpg",
    sp: {
      metadata_url: "", // Customer must provide their ServiceNow metadata URL
    },
    claim_mappings: {
      saml_to_oidc: {
        UserPrincipalName: ["email"],
      },
      oidc_to_saml: {
        email: ["UserPrincipalName"],
      },
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
        source_claim: "email",
      },
    },
    editable_fields: [
      "login_url",
      "logo_url",
      "sp.metadata_url",
      "claim_mappings",
    ],
    locked_fields: [],
  },

  custom: {
    id: "custom",
    display_name: "",
    login_url: "",
    logo_url: "",
    sp: {
      metadata_url: "",
    },
    claim_mappings: {
      saml_to_oidc: {},
      oidc_to_saml: {},
    },
    saml: {
      nameid: {
        format: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
        source_claim: "email",
      },
    },
    editable_fields: ["*"],
    locked_fields: [],
  },
};

/**
 * Get a template by ID. Returns a deep copy to avoid mutations.
 *
 * @param {string} templateId - Template ID (e.g., "microsoft", "dropbox", "custom")
 * @returns {Object|null} Template object or null if not found
 */
export function getTemplate(templateId) {
  const template = RP_TEMPLATES[templateId];
  if (!template) return null;
  return JSON.parse(JSON.stringify(template));
}

/**
 * List all available template IDs and display names.
 *
 * @returns {Array<{id: string, display_name: string}>}
 */
export function listTemplates() {
  return Object.entries(RP_TEMPLATES).map(([id, template]) => ({
    id,
    display_name: template.display_name || "Custom",
  }));
}

/** Request body aliases that end up as the gateway's sp.metadata_url. */
export const SP_METADATA_URL_FIELDS = ["sp_metadata_url", "metadataUrl"];

/**
 * The shared SAML gateway fetches SP metadata from this URL (amfa-442 A3):
 * https only, no literal IP, no localhost. Empty values are not checked here
 * (presence is decided by the handler).
 *
 * @param {unknown} value
 * @returns {boolean}
 */
export function isPublicHttpsUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.protocol !== "https:") return false;
  const host = url.hostname.toLowerCase();
  // A terminal dot is the DNS root and resolves identically (localhost. == localhost).
  const name = host.endsWith(".") ? host.slice(0, -1) : host;
  if (name === "localhost" || name.endsWith(".localhost")) return false;
  // IPv6 literals keep their brackets in URL.hostname; IPv4 literals are digits and dots.
  if (host.startsWith("[") || /^\d+(\.\d+){3}$/.test(host)) return false;
  return true;
}

/**
 * Templates that lock sp.metadata_url must keep their own value: a payload
 * may echo the template's URL back but may not replace it (amfa-442 A3).
 *
 * @param {string|undefined} templateId
 * @param {Object} payload request body
 * @returns {string|null} message naming the field, or null when allowed
 */
export function lockedMetadataUrlViolation(templateId, payload) {
  const tmpl = templateId && templateId !== "custom" ? getTemplate(templateId) : null;
  if (!tmpl?.locked_fields?.includes("sp.metadata_url")) return null;
  for (const field of SP_METADATA_URL_FIELDS) {
    const value = payload?.[field];
    if (value && value !== tmpl.sp.metadata_url) {
      return `${field}: locked by the ${templateId} template`;
    }
  }
  return null;
}

/**
 * NameID format options for the UI dropdown.
 */
export const NAMEID_FORMATS = [
  {
    id: "urn:oasis:names:tc:SAML:2.0:nameid-format:persistent",
    name: "Persistent",
  },
  {
    id: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
    name: "Email Address",
  },
  {
    id: "urn:oasis:names:tc:SAML:2.0:nameid-format:transient",
    name: "Transient",
  },
  {
    id: "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
    name: "Unspecified",
  },
];

export default RP_TEMPLATES;
