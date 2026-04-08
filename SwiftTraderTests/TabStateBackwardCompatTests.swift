import Testing
import Foundation
@testable import SwiftTrader

/// These tests ensure that saved WorkspaceState JSON from older versions
/// (before new fields were added) still decodes correctly. If you add a new
/// field to ChartTabState, CorrelationTabState, or WorkspaceState, you MUST
/// use `decodeIfPresent` with a default — and the baseline JSON below will
/// catch you if you forget.

@Suite("TabState backward compatibility")
struct TabStateBackwardCompatTests {

    // Baseline JSON: the minimum shape that existed before ATR fields were added.
    // Do NOT add new keys here — that defeats the purpose. Only the original
    // fields belong in this fixture.
    // Note: Swift's auto-synthesized Codable for enums with associated values
    // wraps the payload in {"_0": ...}. These fixtures match that format.
    private static let baselineChartJSON = """
    {
        "id": "00000000-0000-0000-0000-000000000001",
        "content": {
            "chart": {
                "_0": {
                    "instrument": "EURUSD",
                    "period": "FIFTEEN_MINS",
                    "showSessions": true,
                    "showVolume": true,
                    "showEMA": true,
                    "emaConfigs": []
                }
            }
        }
    }
    """.data(using: .utf8)!

    private static let baselineCorrelationJSON = """
    {
        "id": "00000000-0000-0000-0000-000000000002",
        "content": {
            "correlation": {
                "_0": {
                    "currency": "EUR",
                    "period": "ONE_MIN",
                    "showSessions": true,
                    "showVolume": false,
                    "showEMA": false,
                    "emaConfigs": []
                }
            }
        }
    }
    """.data(using: .utf8)!

    private static let baselineWorkspaceJSON = """
    {
        "tabs": [
            {
                "id": "00000000-0000-0000-0000-000000000001",
                "content": {
                    "chart": {
                        "_0": {
                            "instrument": "GBPUSD",
                            "period": "ONE_HOUR",
                            "showSessions": false,
                            "showVolume": true,
                            "showEMA": true,
                            "emaConfigs": [{"period": 20, "red": 1, "green": 1, "blue": 0, "alpha": 1}]
                        }
                    }
                }
            }
        ],
        "selectedTabIndex": 0,
        "showBottomPanel": true,
        "showRightPanel": false
    }
    """.data(using: .utf8)!

    @Test("Chart tab decodes from baseline JSON without new fields")
    func chartTabBackwardCompat() throws {
        let tab = try JSONDecoder().decode(TabState.self, from: Self.baselineChartJSON)
        if case .chart(let state) = tab.content {
            #expect(state.instrument == "EURUSD")
            #expect(state.showATR == true)
            #expect(state.atrPeriod == 14)
        } else {
            Issue.record("Expected chart content")
        }
    }

    @Test("Correlation tab decodes from baseline JSON without new fields")
    func correlationTabBackwardCompat() throws {
        let tab = try JSONDecoder().decode(TabState.self, from: Self.baselineCorrelationJSON)
        if case .correlation(let state) = tab.content {
            #expect(state.currency == "EUR")
            #expect(state.showATR == true)
            #expect(state.atrPeriod == 14)
        } else {
            Issue.record("Expected correlation content")
        }
    }

    @Test("Full workspace decodes from baseline JSON without new fields")
    func workspaceBackwardCompat() throws {
        let workspace = try JSONDecoder().decode(WorkspaceState.self, from: Self.baselineWorkspaceJSON)
        #expect(workspace.tabs.count == 1)
        #expect(workspace.showBottomPanel == true)
        #expect(workspace.showRightPanel == false)
    }
}
