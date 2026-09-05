import { beforeEach, expect, test, vi } from 'vitest'
import type { User } from '@prisma/client'
const mocks = vi.hoisted(() => ({ findMany: vi.fn(), updateMany: vi.fn(), geo: vi.fn() }))
vi.mock('../src/config', () => ({ config: { GEOIP_ENABLED: false } }))
vi.mock('../src/prisma', () => ({ prisma: { session: { findMany: mocks.findMany }, device: { updateMany: mocks.updateMany } }, bytesToNumber: Number }))
vi.mock('../src/lib/deviceLimit', () => ({ effectiveDeviceLimit: () => 5 }))
vi.mock('../src/services/geo', () => ({ lookupOrigin: mocks.geo }))
vi.mock('../src/services/nodes', () => ({ loadPublicNodes: async (nodes: unknown[]) => nodes }))
vi.mock('../src/services/serviceControl', () => ({ serviceStatus: async () => ({}), serviceSettings: async () => ({}) }))
vi.mock('../src/services/egressBudget', () => ({ egressBudgetView: vi.fn() }))
import { accountActiveMap, deviceEstimate, recordMapCountry } from '../src/services/accountInsights'

beforeEach(() => { vi.clearAllMocks(); mocks.updateMany.mockResolvedValue({ count: 1 }) })
test('country estimate is labelled and unknown locations stay unknown', () => {
 expect(deviceEstimate('KZ')).toMatchObject({ lat: 48, lon: 68, source: 'device-estimate', approximate: true })
 expect(deviceEstimate('US')?.lon).toBe(-98.6)
 expect(deviceEstimate('XX')).toBeNull()
 expect(deviceEstimate(null)).toBeNull()
})
test('a device cannot update another account or device using the report body', async () => {
 await recordMapCountry('owner', 'current-device', 'KZ')
 expect(mocks.updateMany).toHaveBeenCalledWith(expect.objectContaining({ where: expect.objectContaining({ userId:'owner', id:'current-device', status:'ACTIVE' }), data:{ mapCountryCode:'KZ' } }))
})
test('two devices retain different positions with GeoIP disabled; pending is separate', async () => {
 mocks.findMany.mockResolvedValue([
  ['phone','KZ','ACTIVE'],['pc','US','ACTIVE'],['browser',null,'PENDING'],
 ].map(([id,country,status]) => ({ id, deviceId:id, status, connectedAt:new Date(), clientIp:null, device:{deviceName:id,platform:id,mapCountryCode:country}, node:{id:'node-'+id,location:{lat:50.11,lon:8.68}} })))
 const result=await accountActiveMap({id:'owner'} as User,'phone')
 expect(result.activeTunnels).toBe(2);expect(result.pendingTunnels).toBe(1)
 expect(result.devices.find(d=>d.id==='phone')?.origin?.countryCode).toBe('KZ')
 expect(result.devices.find(d=>d.id==='pc')?.origin?.countryCode).toBe('US')
 expect(result.devices.find(d=>d.id==='browser')?.connected).toBe(false)
 expect(mocks.geo).not.toHaveBeenCalled()
 expect(mocks.findMany).toHaveBeenCalledWith(expect.objectContaining({where:expect.objectContaining({userId:'owner'})}))
})
