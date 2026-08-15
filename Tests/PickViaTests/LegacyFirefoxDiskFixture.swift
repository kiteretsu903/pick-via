import Foundation

enum LegacyFirefoxDiskFixture {
  static let rawTargetID =
    "/Users/private-user/Library/Application Support/Firefox/Profiles/legacy-target-id"
  static let rawProfilePath =
    "/Users/private-user/Library/Application Support/Firefox/Profiles/legacy-profile"
  static let canonicalProfileIdentity =
    "firefox-profile-v1:64c1b2743b8f168cd1847de57912d041fe0b5dba870ac27bb9750a46ba689e7a"
  static let collidingTargetID =
    "firefox-runtime-target|firefox-profile-v1:"
    + "4fb71837ca8b29f3f6a33e5d5b9f9dcc774f23ab9aabf20ebb68db819dfebdcf"

  static let document = """
    {
      "schemaVersion": 2,
      "browsers": [
        {
          "id": "org.mozilla.firefox",
          "family": "firefox",
          "displayName": "Firefox",
          "bundleIdentifier": "org.mozilla.firefox",
          "isAvailable": true
        }
      ],
      "targets": [
        {
          "id": "\(rawTargetID)",
          "browserID": "org.mozilla.firefox",
          "label": "Legacy Firefox",
          "profileIdentifier": "Authoritative Profile",
          "profileDisplayName": "Authoritative Display",
          "profileIdentity": "\(rawProfilePath)",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 0,
          "origin": "manual",
          "availability": "available",
          "pendingDefaultMigration": false,
          "validationError": "Authoritative validation"
        },
        {
          "id": "\(collidingTargetID)",
          "browserID": "org.mozilla.firefox",
          "label": "Collision Target",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 1,
          "origin": "manual",
          "availability": "available",
          "pendingDefaultMigration": false,
          "validationError": "Collision validation"
        }
      ]
    }
    """

  static func nameOnlyAvailableDetectedDocument(targetID: String) -> String {
    """
    {
      "schemaVersion": 2,
      "browsers": [
        {
          "id": "org.mozilla.firefox",
          "family": "firefox",
          "displayName": "Firefox",
          "bundleIdentifier": "org.mozilla.firefox",
          "isAvailable": true
        }
      ],
      "targets": [
        {
          "id": "\(targetID)",
          "browserID": "org.mozilla.firefox",
          "label": "Legacy Name Only",
          "profileIdentifier": "Legacy Name Only",
          "profileDisplayName": "Legacy Name Only",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 0,
          "origin": "detected",
          "availability": "available"
        },
        {
          "id": "org.mozilla.firefox||private",
          "browserID": "org.mozilla.firefox",
          "label": "Firefox Private",
          "mode": "private",
          "isEnabled": true,
          "sortOrder": 1,
          "origin": "detected",
          "availability": "available"
        }
      ]
    }
    """
  }

  static func pathShapedNameOnlyDetectedDocument(
    encodedProfilePath: String,
    includeBrowserDefault: Bool = true
  ) -> String {
    let browserDefault =
      includeBrowserDefault
      ? """
      ,
          {
            "id": "org.mozilla.firefox||normal",
            "browserID": "org.mozilla.firefox",
            "label": "Firefox Default",
            "mode": "normal",
            "isEnabled": true,
            "sortOrder": 1,
            "origin": "detected",
            "availability": "available"
          }
      """
      : ""
    return """
      {
        "schemaVersion": 2,
        "browsers": [
          {
            "id": "org.mozilla.firefox",
            "family": "firefox",
            "displayName": "Firefox",
            "bundleIdentifier": "org.mozilla.firefox",
            "isAvailable": true
          }
        ],
        "targets": [
          {
            "id": "legacy-path-shaped-name",
            "browserID": "org.mozilla.firefox",
            "label": "Path-shaped Profile",
            "profileIdentifier": "\(encodedProfilePath)",
            "profileDisplayName": "\(encodedProfilePath)",
            "mode": "normal",
            "isEnabled": true,
            "sortOrder": 0,
            "origin": "detected",
            "availability": "available"
          }\(browserDefault)
        ]
      }
      """
  }

  static func detectedCanonicalCollisionDocument(
    rawIdentityPath: String,
    rawIdentityCanonicalTargetID: String,
    nameOnlyCanonicalTargetID: String
  ) -> String {
    """
    {
      "schemaVersion": 2,
      "browsers": [
        {
          "id": "org.mozilla.firefox",
          "family": "firefox",
          "displayName": "Firefox",
          "bundleIdentifier": "org.mozilla.firefox",
          "isAvailable": true
        }
      ],
      "targets": [
        {
          "id": "legacy-detected-raw-identity",
          "browserID": "org.mozilla.firefox",
          "label": "Raw Identity Profile",
          "profileIdentifier": "Raw Profile",
          "profileDisplayName": "Raw Display",
          "profileIdentity": "\(rawIdentityPath)",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 0,
          "origin": "detected",
          "availability": "available",
          "validationError": "Raw runtime-only validation"
        },
        {
          "id": "\(rawIdentityCanonicalTargetID)",
          "browserID": "org.mozilla.firefox",
          "label": "Raw Collision Owner",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 1,
          "origin": "manual",
          "availability": "available",
          "validationError": "Raw collision validation"
        },
        {
          "id": "legacy-detected-name-only",
          "browserID": "org.mozilla.firefox",
          "label": "Name Only Profile",
          "profileIdentifier": "Legacy Name Collision",
          "profileDisplayName": "Legacy Name Collision",
          "mode": "private",
          "isEnabled": true,
          "sortOrder": 2,
          "origin": "detected",
          "availability": "available",
          "validationError": "Name runtime-only validation"
        },
        {
          "id": "\(nameOnlyCanonicalTargetID)",
          "browserID": "org.mozilla.firefox",
          "label": "Name Collision Owner",
          "mode": "private",
          "isEnabled": false,
          "sortOrder": 3,
          "origin": "manual",
          "availability": "available",
          "validationError": "Name collision validation"
        },
        {
          "id": "unrelated-removable",
          "browserID": "org.mozilla.firefox",
          "label": "Unrelated Manual",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 4,
          "origin": "manual",
          "availability": "available"
        }
      ]
    }
    """
  }

  static func firefoxProfileChangeDocument(
    selectedIdentity: String,
    encodedLegacyPath: String
  ) -> String {
    """
    {
      "schemaVersion": 2,
      "browsers": [
        {
          "id": "org.mozilla.firefox",
          "family": "firefox",
          "displayName": "Firefox",
          "bundleIdentifier": "org.mozilla.firefox",
          "isAvailable": true
        }
      ],
      "targets": [
        {
          "id": "org.mozilla.firefox|\(selectedIdentity)|normal",
          "browserID": "org.mozilla.firefox",
          "label": "Selected Firefox Profile",
          "profileIdentifier": "selected-launch",
          "profileDisplayName": "Selected Display",
          "profileIdentity": "\(selectedIdentity)",
          "profileLaunchPath": "/Users/runtime-only/Firefox/Profiles/selected",
          "mode": "normal",
          "isEnabled": true,
          "sortOrder": 0,
          "origin": "detected",
          "availability": "available",
          "validationError": "Selected runtime-only validation"
        },
        {
          "id": "manual-profile-change",
          "browserID": "org.mozilla.firefox",
          "label": "Manual Firefox",
          "mode": "private",
          "isEnabled": true,
          "sortOrder": 1,
          "origin": "manual",
          "availability": "available"
        },
        {
          "id": "legacy-encoded-profile",
          "browserID": "org.mozilla.firefox",
          "label": "Encoded Legacy Profile",
          "profileIdentifier": "\(encodedLegacyPath)",
          "profileDisplayName": "\(encodedLegacyPath)",
          "mode": "private",
          "isEnabled": true,
          "sortOrder": 2,
          "origin": "detected",
          "availability": "available"
        },
        {
          "id": "org.mozilla.firefox||private",
          "browserID": "org.mozilla.firefox",
          "label": "Firefox Private Default",
          "mode": "private",
          "isEnabled": true,
          "sortOrder": 3,
          "origin": "detected",
          "availability": "available"
        }
      ]
    }
    """
  }
}
