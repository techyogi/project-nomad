import { inject } from '@adonisjs/core'
import { DockerService } from './docker_service.js'
import { SERVICE_NAMES } from '../../constants/service_names.js'
import logger from '@adonisjs/core/services/logger'
import axios from 'axios'

interface NominatimSearchResult {
  place_id: number
  licence: string
  osm_type: string
  osm_id: number
  lat: string
  lon: string
  display_name: string
  type: string
  importance: number
  address?: Record<string, string>
}

export interface NominatimPlace {
  name: string
  displayName: string
  type: string
  coordinates: [number, number]
}

@inject()
export class NominatimService {
  private baseUrl: string | null = null
  private initPromise: Promise<void> | null = null

  private async _initialize() {
    if (!this.initPromise) {
      this.initPromise = (async () => {
        const dockerService = new DockerService()
        // Check if Nominatim is installed
        const url = await dockerService.getServiceURL(SERVICE_NAMES.NOMINATIM)
        if (!url) {
          throw new Error('Nominatim service is not installed or running.')
        }
        // Use the container name with internal port (8080) for Docker network access
        const hostname = process.env.NODE_ENV === 'production'
          ? `http://${SERVICE_NAMES.NOMINATIM}:8080`
          : url
        this.baseUrl = hostname
      })()
    }
    return this.initPromise
  }

  async isAvailable(): Promise<boolean> {
    try {
      await this._initialize()
      if (!this.baseUrl) return false
      const response = await axios.get(`${this.baseUrl}/search`, {
        params: { q: 'test', format: 'json', limit: 1 },
        timeout: 3000,
      })
      return response.status === 200
    } catch {
      this.initPromise = null
      return false
    }
  }

  async search(query: string, limit: number = 10): Promise<NominatimPlace[]> {
    await this._initialize()
    if (!this.baseUrl) {
      throw new Error('Nominatim service is not available.')
    }

    try {
      const response = await axios.get<NominatimSearchResult[]>(`${this.baseUrl}/search`, {
        params: {
          q: query.replace(/,/g, ' ').replace(/\s+/g, ' ').trim(),
          format: 'json',
          limit,
          addressdetails: 1,
          countrycodes: 'us',
        },
        timeout: 10000,
      })

      return response.data.map((result) => {
        // Build a concise name from address parts when available
        let name = result.display_name.split(',')[0]
        if (result.address) {
          const a = result.address
          const parts = []
          if (a.house_number) parts.push(a.house_number)
          if (a.road) parts.push(a.road)
          if (parts.length > 0) {
            name = parts.join(' ')
          } else if (a.town || a.city || a.village) {
            name = a.town || a.city || a.village || name
          }
        }
        return {
          name,
          displayName: result.display_name,
          type: result.type,
          coordinates: [parseFloat(result.lon), parseFloat(result.lat)] as [number, number],
        }
      })
    } catch (error) {
      logger.error(`[NominatimService] Search failed: ${error.message}`)
      return []
    }
  }

  async reverse(lat: number, lon: number): Promise<NominatimPlace | null> {
    await this._initialize()
    if (!this.baseUrl) return null

    try {
      const response = await axios.get(`${this.baseUrl}/reverse`, {
        params: { lat, lon, format: 'json', addressdetails: 1 },
        timeout: 10000,
      })

      if (!response.data || response.data.error) return null

      return {
        name: response.data.display_name.split(',')[0],
        displayName: response.data.display_name,
        type: response.data.type,
        coordinates: [parseFloat(response.data.lon), parseFloat(response.data.lat)],
      }
    } catch (error) {
      logger.error(`[NominatimService] Reverse geocode failed: ${error.message}`)
      return null
    }
  }
}
