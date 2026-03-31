import type { HttpContext } from '@adonisjs/core/http'
import { NominatimService } from '#services/nominatim_service'
import { inject } from '@adonisjs/core'

@inject()
export default class NominatimController {
  constructor(private nominatimService: NominatimService) {}

  async status() {
    const available = await this.nominatimService.isAvailable()
    return { available }
  }

  async search({ request }: HttpContext) {
    const query = request.input('q')
    if (!query || typeof query !== 'string' || !query.trim()) {
      return []
    }

    const limit = Math.min(parseInt(request.input('limit', '10'), 10), 40)
    const results = await this.nominatimService.search(query.trim(), limit)
    return results
  }

  async reverse({ request, response }: HttpContext) {
    const lat = parseFloat(request.input('lat'))
    const lon = parseFloat(request.input('lon'))

    if (isNaN(lat) || isNaN(lon)) {
      return response.status(400).json({ error: 'Parameters "lat" and "lon" are required' })
    }

    const result = await this.nominatimService.reverse(lat, lon)
    return result || response.status(404).json({ error: 'No results found' })
  }
}
